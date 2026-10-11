import XCTest
import SwiftUI
@testable import Obadh

@MainActor
final class VoiceSessionReliabilityTests: XCTestCase {
    private func session(
        capture: FakeCapture = FakeCapture(), pipelines: PipelineFactory = PipelineFactory(),
        permission: @escaping () async -> Bool = { true }, timeout: TimeInterval = 4,
        directory: URL? = nil
    ) -> VoiceSessionController {
        let folder = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        if directory == nil {
            try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        }
        return VoiceSessionController(
            directory: folder, capture: capture, makePipeline: { pipelines.make() },
            modelConfiguration: { fakeConfiguration }, permission: permission,
            configureSession: {}, deactivateSession: {}, finishTimeout: timeout, observeSystem: false)
    }

    private func drain() async {
        // Callbacks use the production main-queue hop.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testCancelWhilePermissionIsPendingCannotStartMicrophone() async {
        let gate = PermissionGate()
        let capture = FakeCapture()
        let controller = session(capture: capture, permission: { await gate.wait() })
        let start = Task { await controller.startDictation("cancelled") }
        while gate.continuation == nil { await Task.yield() }
        controller.cancelDictation()
        gate.resolve(true)
        await start.value
        XCTAssertEqual(capture.starts, 0)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.dictationID)
    }

    func testDuplicateURLDuringStartupCoalescesAndFinishedURLDoesNotEraseText() async {
        let gate = PermissionGate()
        let capture = FakeCapture()
        let pipes = PipelineFactory()
        let controller = session(capture: capture, pipelines: pipes, permission: { await gate.wait() })
        let start = Task { await controller.startDictation("same") }
        while gate.continuation == nil { await Task.yield() }
        await controller.startDictation("same")
        gate.resolve(true)
        await start.value
        XCTAssertEqual(capture.starts, 1)
        let pipe = pipes.items[0]
        pipe.emit("শেষ কথা", final: true)
        pipe.onFinished?("same")
        await drain()
        await controller.startDictation("same")
        XCTAssertEqual(capture.starts, 1)
        XCTAssertEqual(controller.transcript.text, "শেষ কথা")
        controller.cancelDictation()
    }

    func testSupersededPermissionRequestCannotReplaceNewTrip() async {
        let gate = PermissionGate()
        var requests = 0
        let capture = FakeCapture()
        let controller = session(capture: capture, permission: {
            requests += 1
            return requests == 1 ? await gate.wait() : true
        })
        let old = Task { await controller.startDictation("old") }
        while gate.continuation == nil { await Task.yield() }
        await controller.startDictation("new")
        gate.resolve(true)
        await old.value
        XCTAssertEqual(controller.dictationID, "new")
        XCTAssertEqual(controller.phase, .listening)
        XCTAssertEqual(capture.starts, 1)
        controller.cancelDictation()
    }

    func testLateCallbacksFromCancelledPipelineCannotAffectNewAttempt() async {
        let pipes = PipelineFactory()
        let controller = session(pipelines: pipes)
        await controller.startDictation("old")
        let old = pipes.items[0]
        await controller.startDictation("new")
        old.emit("পুরোনো লেখা", final: true)
        old.onFinished?("old")
        old.onStreamingReady?(false)
        old.onFailure?("old", .audioOverflow)
        await drain()
        XCTAssertEqual(controller.dictationID, "new")
        XCTAssertEqual(controller.phase, .listening)
        XCTAssertNil(controller.failure)
        XCTAssertEqual(controller.transcript, .empty)
        controller.cancelDictation()
    }

    func testFinishDeadlineStopsMicAndPreservesPartialTextForRecovery() async throws {
        let capture = FakeCapture()
        let pipes = PipelineFactory()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = session(capture: capture, pipelines: pipes, timeout: 0.02, directory: folder)
        await controller.startDictation("slow")
        pipes.items[0].emit("আমার দীর্ঘ কথা", final: false)
        await drain()
        controller.finishDictation()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(capture.running)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.failure, .finishTimedOut)
        XCTAssertEqual(controller.transcript.text, "আমার দীর্ঘ কথা")
        XCTAssertFalse(controller.hasFinalText, "Incomplete words must not be advertised as ready to insert")
        // A process restart can still recover the words from the persisted result.
        let restored = session(directory: folder)
        XCTAssertEqual(restored.transcript.text, controller.transcript.text)
        XCTAssertEqual(restored.failure, .finishTimedOut)
        controller.cancelDictation()
    }

    func testLeavingDuringPostRollClampsFinishAndStopsMicrophoneImmediately() async {
        let capture = FakeCapture()
        let pipes = PipelineFactory()
        let controller = session(capture: capture, pipelines: pipes)
        await controller.startDictation("back")
        controller.finishDictation()
        controller.applicationWillResignActive()
        XCTAssertEqual(pipes.items[0].finishes, [true, false])
        XCTAssertFalse(capture.running)
        controller.cancelDictation()
    }

    func testOverflowStopsAndPreservesWordsButDoesNotPublishSuccess() async {
        let pipes = PipelineFactory()
        let capture = FakeCapture()
        let controller = session(capture: capture, pipelines: pipes)
        await controller.startDictation("overflow")
        pipes.items[0].emit("রাখার কথা", final: false)
        pipes.items[0].onFailure?("overflow", .audioOverflow)
        await drain()
        XCTAssertEqual(controller.failure, .audioOverflow)
        XCTAssertEqual(controller.transcript.text, "রাখার কথা")
        XCTAssertFalse(capture.running)
        XCTAssertFalse(controller.hasFinalText)
        controller.cancelDictation()
    }

    func testPermissionDeniedNeverStartsCaptureAndPublishesMatchingID() async {
        let capture = FakeCapture()
        let controller = session(capture: capture, permission: { false })
        await controller.startDictation("denied")
        XCTAssertEqual(capture.starts, 0)
        XCTAssertEqual(controller.dictationID, "denied")
        XCTAssertEqual(controller.failure, .microphonePermissionDenied)
        controller.cancelDictation()
    }

    func testCancelWritesMatchingTombstoneAndForegroundReadsMissedAcknowledgement() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pipes = PipelineFactory()
        let controller = session(pipelines: pipes, directory: folder)
        await controller.startDictation("cancel")
        controller.cancelDictation()
        let tombstone = try XCTUnwrap(VoiceMessageFile.read(VoiceSessionSnapshot.self,
            from: VoiceSessionChannel.snapshotURL(in: folder)))
        XCTAssertEqual(tombstone.dictationID, "cancel")
        XCTAssertEqual(tombstone.phase, .idle)
        XCTAssertFalse(tombstone.transcript.isFinal)

        await controller.startDictation("deliver")
        pipes.items.last!.emit("লেখা", final: true)
        pipes.items.last!.onFinished?("deliver")
        await drain()
        try VoiceMessageFile.write(VoiceCommand(seq: 1, kind: .acknowledge,
            dictationID: "deliver", issuedAt: Date().addingTimeInterval(-3_600)),
            to: VoiceSessionChannel.commandURL(in: folder))
        controller.refreshAcknowledgement()
        XCTAssertNil(controller.dictationID)
        XCTAssertEqual(controller.transcript.text, "")
    }

    func testVoiceScreenRendersLongRecoveryAtAccessibilitySize() async throws {
        let pipes = PipelineFactory()
        let controller = session(pipelines: pipes)
        await controller.startDictation("render")
        pipes.items[0].emit(Array(repeating: "আমি বাংলায় কথা বলি", count: 250).joined(separator: " "), final: false)
        pipes.items[0].onFailure?("render", .audioOverflow)
        await drain()
        let screen = UIHostingController(rootView: VoiceSessionScreen(session: controller, models: .shared, onClose: {})
            .environment(\.dynamicTypeSize, .accessibility1))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = screen
        window.makeKeyAndVisible()
        screen.view.frame = window.bounds
        screen.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        screen.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "voice-long-recovery-accessibility"
        attachment.lifetime = .keepAlways
        add(attachment)
        window.isHidden = true
        previousKey?.makeKey()
        controller.cancelDictation()
    }

    func testUnavailableSharedDirectoryFailsBeforeStartingMicrophone() async {
        let capture = FakeCapture()
        let controller = VoiceSessionController(directory: nil, capture: capture,
            permission: { true }, configureSession: {}, deactivateSession: {}, observeSystem: false)
        await controller.startDictation("unavailable")
        XCTAssertEqual(capture.starts, 0)
        XCTAssertEqual(controller.failure, .deliveryUnavailable)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testFinalWriteFailureKeepsTextVisibleForCopy() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pipes = PipelineFactory()
        let controller = session(pipelines: pipes, directory: folder)
        await controller.startDictation("write-failure")
        try FileManager.default.removeItem(at: folder)
        pipes.items[0].emit("কপি করার কথা", final: true)
        pipes.items[0].onFinished?("write-failure")
        await drain()
        XCTAssertEqual(controller.transcript.text, "কপি করার কথা")
        XCTAssertEqual(controller.failure, .deliveryUnavailable)
        XCTAssertFalse(controller.hasFinalText)
        XCTAssertEqual(controller.phase, .idle)
    }
}

private let fakeConfiguration = VoiceRecognitionPipeline.StreamingConfiguration(paths: .init(
    encoder: URL(fileURLWithPath: "/unused"), decoder: URL(fileURLWithPath: "/unused"),
    joiner: URL(fileURLWithPath: "/unused"), tokens: URL(fileURLWithPath: "/unused"), modelType: "fake"))

@MainActor
private final class PermissionGate {
    var continuation: CheckedContinuation<Bool, Never>?
    func wait() async -> Bool { await withCheckedContinuation { continuation = $0 } }
    func resolve(_ allowed: Bool) { continuation?.resume(returning: allowed); continuation = nil }
}

@MainActor
private final class PipelineFactory {
    var items: [FakePipeline] = []
    func make() -> FakePipeline { let pipe = FakePipeline(); items.append(pipe); return pipe }
}

private final class FakeCapture: VoiceAudioCapturing {
    var isMetering = false
    var hasDelivered = true
    var lastBufferAt: CFTimeInterval { CACurrentMediaTime() }
    var onSamples: (@Sendable (UnsafeBufferPointer<Float>) -> Void)?
    var onFailure: (@Sendable (Error) -> Void)?
    var starts = 0
    var running = false
    func start() throws { starts += 1; running = true }
    func restart() throws { running = true }
    func stop() { running = false }
}

private final class FakePipeline: VoiceRecognizing, @unchecked Sendable {
    // Driven only by the main actor in these controller tests.
    var onTranscript: (@Sendable (String, VoiceTranscript) -> Void)?
    var onStreamingReady: (@Sendable (Bool) -> Void)?
    var onFinished: (@Sendable (String) -> Void)?
    var onVoiceActivity: (@Sendable () -> Void)?
    var onFailure: (@Sendable (String, VoiceSessionFailure) -> Void)?
    var id = ""
    var finishes: [Bool] = []
    func load(streaming: VoiceRecognitionPipeline.StreamingConfiguration) { onStreamingReady?(true) }
    func begin(dictationID: String) { id = dictationID }
    func append(_ samples: UnsafeBufferPointer<Float>) {}
    func finish(postRoll: Bool) { finishes.append(postRoll) }
    func cancel() {}
    func unload() {}
    func emit(_ text: String, final: Bool) {
        onTranscript?(id, VoiceTranscript(text: text, stableLength: text.count, isFinal: final))
    }
}
