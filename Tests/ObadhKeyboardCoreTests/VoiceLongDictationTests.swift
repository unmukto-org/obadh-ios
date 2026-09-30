import Foundation
import XCTest
@testable import ObadhKeyboardCore

/// Stress the pure text/transport layer. These do not simulate recognizer speed,
/// microphone interruptions, UIKit delivery, or the SwiftUI scrolling behavior.
final class VoiceLongDictationTests: XCTestCase {
    @MainActor
    func testTenThousandWordsRoundTripAndInsertWithNarrowHostContext() throws {
        let text = Array(repeating: "বাংলাদেশ স্বাধীনতার কথা শুনি আজ", count: 2_000)
            .joined(separator: " ")
        let snapshot = VoiceSessionSnapshot(
            seq: 1, phase: .idle, heartbeat: Date(), dictationID: "long",
            transcript: VoiceTranscript(text: text, stableLength: text.count, isFinal: true),
            failure: nil)
        let encoded = try VoiceMessageFile.encode(snapshot)
        let decoded = try XCTUnwrap(VoiceMessageFile.decode(VoiceSessionSnapshot.self, from: encoded))
        XCTAssertEqual(decoded, snapshot)

        let document = WindowedDocument(window: 12)
        document.insertText("আগের লেখা")
        var reconciler = VoiceDraftReconciler()
        reconciler.begin(dictationID: "long", contextBefore: document.contextBeforeInput)
        let step = try XCTUnwrap(reconciler.step(for: decoded))
        XCTAssertEqual(VoiceDraftWriter().apply(step, in: document), .applied)
        XCTAssertEqual(document.fullText, "আগের লেখা " + text)
        XCTAssertTrue(step.completesDictation)
    }

    func testManyClosedPhrasesPreserveEveryWord() {
        var builder = VoiceTranscriptBuilder()
        var phrases: [String] = []
        for index in 0..<100 {
            let phrase = "পর্ব \(index) " + Array(repeating: "আমি বাংলায় কথা বলি", count: 40)
                .joined(separator: " ")
            phrases.append(phrase)
            builder.setOpenPhrase(phrase)
            builder.commitAll()
            builder.closeOpenPhrase(final: phrase)
        }
        builder.finish()
        XCTAssertEqual(builder.transcript.text, phrases.joined(separator: " "))
        XCTAssertEqual(builder.transcript.stableLength, builder.transcript.text.count)
        XCTAssertTrue(builder.transcript.isFinal)
    }

    func testTwentyMinutesOfAudioWithConsumerKeepingUpHasNoGaps() {
        let ring = VoiceAudioRing(seconds: 60)
        var cursor: Int64 = 0
        for second in 0..<1_200 {
            ring.write([Float](repeating: Float(second), count: 16_000))
            let read = ring.read(from: cursor, maxCount: 16_000)
            XCTAssertEqual(read.start, cursor)
            XCTAssertEqual(read.samples.count, 16_000)
            XCTAssertEqual(read.samples.first, Float(second))
            XCTAssertEqual(read.samples.last, Float(second))
            cursor = read.next
        }
        XCTAssertEqual(cursor, 1_200 * 16_000)
        XCTAssertEqual(ring.capacity, 60 * 16_000)
    }
}
