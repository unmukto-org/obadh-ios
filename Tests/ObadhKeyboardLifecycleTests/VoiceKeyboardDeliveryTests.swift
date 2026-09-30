import XCTest
import UIKit

@MainActor
final class VoiceKeyboardDeliveryTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        suite = "voice-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }

    private func coordinator(_ host: DeliveryHost) -> VoiceKeyboardCoordinator {
        let folder = directory!
        let result = VoiceKeyboardCoordinator(persistence: defaults, returnWait: 0.01, directory: { folder })
        result.host = host
        result.hostWillAppear()
        result.hostDidAppear()
        return result
    }

    private func publish(_ id: String, text: String = "আমার বাংলা", failure: VoiceSessionFailure? = nil) throws {
        let snapshot = VoiceSessionSnapshot(
            seq: 1, phase: .idle, heartbeat: Date(), dictationID: id,
            transcript: VoiceTranscript(text: text, stableLength: text.count, isFinal: true), failure: failure)
        try VoiceMessageFile.write(snapshot, to: VoiceSessionChannel.snapshotURL(in: directory))
    }

    func testHiddenAndWillAppearOnlyControllersCannotInsertOrAcknowledge() throws {
        let host = DeliveryHost()
        let voice = coordinator(host)
        voice.micTapped()
        try publish(host.id)
        voice.deliverIfReady() // Also models an already-queued Darwin callback.
        voice.hostWillAppear()
        voice.deliverIfReady()
        XCTAssertEqual(host.document.insertions, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: VoiceSessionChannel.commandURL(in: directory).path))
        voice.hostDidAppear()
        XCTAssertEqual(host.document.insertions, ["আমার বাংলা"])
        voice.hostDidDisappear()
    }

    func testSuccessorOwnsDeliveryAndOldControllerCannotReplayIt() throws {
        let firstHost = DeliveryHost()
        let first = coordinator(firstHost)
        first.micTapped()
        let successorHost = DeliveryHost()
        let successor = coordinator(successorHost)
        try publish(firstHost.id)
        first.deliverIfReady()
        successor.deliverIfReady()
        successor.deliverIfReady()
        first.hostDidAppear()
        first.deliverIfReady()
        XCTAssertEqual(firstHost.document.insertions, [])
        XCTAssertEqual(successorHost.document.insertions, ["আমার বাংলা"])
        first.hostDidDisappear()
    }

    func testSlowFinalSurvivesWaitNoticeAndProcessStyleRecreation() async throws {
        let host = DeliveryHost()
        var voice: VoiceKeyboardCoordinator? = coordinator(host)
        voice?.micTapped()
        voice?.hostDidAppear()
        try await Task.sleep(for: .milliseconds(50))
        voice?.hostDidDisappear()
        voice = nil
        try publish(host.id)
        let nextHost = DeliveryHost()
        let next = coordinator(nextHost)
        XCTAssertEqual(nextHost.document.insertions, ["আমার বাংলা"])
        next.hostDidDisappear()
    }

    func testLateOpenFailureCannotClearANewerTrip() throws {
        let oldHost = DeliveryHost()
        let old = coordinator(oldHost)
        old.micTapped()
        let nextHost = DeliveryHost()
        let next = coordinator(nextHost)
        next.micTapped()
        oldHost.openCompletion?(false)
        try publish(nextHost.id)
        next.hostDidAppear()
        XCTAssertEqual(nextHost.document.insertions, ["আমার বাংলা"])
        next.hostDidDisappear()
    }

    func testReentrantProxyCallbackCannotDeliverTwice() throws {
        let host = DeliveryHost()
        let voice = coordinator(host)
        voice.micTapped()
        try publish(host.id)
        host.onUpdate = { voice.deliverIfReady() }
        voice.hostDidAppear()
        XCTAssertEqual(host.document.insertions.count, 1)
        host.onUpdate = nil
        voice.hostDidDisappear()
    }

    func testIncompleteFailureIsNeverInsertedOrAcknowledged() throws {
        let host = DeliveryHost()
        let voice = coordinator(host)
        voice.micTapped()
        try publish(host.id, failure: .audioOverflow)
        voice.hostDidAppear()
        XCTAssertEqual(host.document.insertions, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: VoiceSessionChannel.commandURL(in: directory).path))
        voice.hostDidDisappear()
    }

    func testTypingAfterReturnPreventsLateInsertionIntoEditedField() throws {
        let host = DeliveryHost()
        let voice = coordinator(host)
        voice.micTapped()
        voice.hostDidAppear()
        voice.finishBeforeTyping()
        host.document.insertText("typed")
        try publish(host.id)
        voice.deliverIfReady()
        XCTAssertEqual(host.document.insertions, ["typed"])
        voice.hostDidDisappear()
    }

    func testCancellationTombstoneClearsOnlyItsOwnPendingTrip() throws {
        let host = DeliveryHost()
        let voice = coordinator(host)
        voice.micTapped()
        let cancelled = VoiceSessionSnapshot(seq: 1, phase: .idle, heartbeat: Date(),
            dictationID: host.id, transcript: .empty, failure: nil)
        try VoiceMessageFile.write(cancelled, to: VoiceSessionChannel.snapshotURL(in: directory))
        voice.hostDidAppear()
        try publish(host.id) // A late final from the cancelled attempt is ignored.
        voice.deliverIfReady()
        XCTAssertEqual(host.document.insertions, [])
        voice.hostDidDisappear()
    }

    func testEmptyFinalCompletesWithoutInsertingWhitespace() throws {
        let host = DeliveryHost()
        host.document.insertText("existing")
        let voice = coordinator(host)
        voice.micTapped()
        try publish(host.id, text: "")
        voice.hostDidAppear()
        XCTAssertEqual(host.document.insertions, ["existing"])
        let ack = VoiceMessageFile.read(VoiceCommand.self, from: VoiceSessionChannel.commandURL(in: directory))
        XCTAssertEqual(ack?.kind, .acknowledge)
        voice.hostDidDisappear()
    }
}

@MainActor
private final class DeliveryHost: VoiceKeyboardHost {
    let document = DeliveryDocument()
    var voiceHasFullAccess = true
    var voiceDocument: TextDocumentEditing { document }
    var id = ""
    var openCompletion: ((Bool) -> Void)?
    var onUpdate: (() -> Void)?
    func voiceWillBeginDictation() {}
    func voiceShowIndicator(_ phase: VoicePanelPhase?) {}
    func voiceMicStateDidChange(_ state: SuggestionMicControl.Mode) {}
    func voicePerformTextUpdate(_ update: () -> Void) { onUpdate?(); update() }
    func voiceOpenContainingApp(_ url: URL, completion: @escaping (Bool) -> Void) {
        id = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!
        openCompletion = completion
    }
}

@MainActor
private final class DeliveryDocument: TextDocumentEditing {
    var insertions: [String] = []
    var contextBeforeInput: String? { insertions.joined() }
    func insertText(_ text: String) { insertions.append(text) }
    func deleteBackward() { XCTFail("Final-only delivery must never delete") }
}
