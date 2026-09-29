import Foundation
import XCTest
@testable import ObadhKeyboardCore

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
            dictationID: "abc", transcript: VoiceTranscript(text: "হ্যালো কথা", stableLength: 5, isFinal: false),
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

