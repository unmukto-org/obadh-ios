import XCTest
@testable import Obadh

final class VoicePipelineReliabilityTests: XCTestCase {
    private var configuration: VoiceRecognitionPipeline.StreamingConfiguration {
        .init(paths: .init(encoder: URL(fileURLWithPath: "/unused"), decoder: URL(fileURLWithPath: "/unused"),
                          joiner: URL(fileURLWithPath: "/unused"), tokens: URL(fileURLWithPath: "/unused"), modelType: "fake"))
    }

    func testOverwrittenUnconsumedAudioReportsFailureInsteadOfSkipping() async {
        let loading = expectation(description: "Model loading")
        let overflow = expectation(description: "Overflow is explicit")
        let unblock = DispatchSemaphore(value: 0)
        let pipeline = VoiceRecognitionPipeline(ring: VoiceAudioRing(seconds: 1, sampleRate: 10)) { _ in
            loading.fulfill()
            _ = unblock.wait(timeout: .now() + 5)
            return StubRecognizer()
        }
        pipeline.onFailure = { id, failure in
            XCTAssertEqual(id, "overflow")
            XCTAssertEqual(failure, .audioOverflow)
            overflow.fulfill()
        }
        pipeline.onFinished = { _ in XCTFail("Missing audio must not look successful") }
        pipeline.begin(dictationID: "overflow")
        pipeline.load(streaming: configuration)
        await fulfillment(of: [loading], timeout: 2)
        pipeline.append([Float](repeating: 0, count: 20))
        unblock.signal()
        await fulfillment(of: [overflow], timeout: 2)
        pipeline.cancel()
        pipeline.unload()
    }

    func testInterruptionShortensPendingPostRollEvenWithNoMoreBuffers() async {
        let finished = expectation(description: "Finish without future audio")
        let pipeline = VoiceRecognitionPipeline { _ in StubRecognizer() }
        pipeline.onFinished = { id in XCTAssertEqual(id, "stop"); finished.fulfill() }
        pipeline.begin(dictationID: "stop")
        pipeline.load(streaming: configuration)
        pipeline.finish(postRoll: true)
        pipeline.finish(postRoll: false)
        await fulfillment(of: [finished], timeout: 2)
        pipeline.cancel()
        pipeline.unload()
    }

    func testCancellationDuringModelLoadSuppressesReadyAndTranscriptCallbacks() async {
        let loading = expectation(description: "Loading")
        let returned = expectation(description: "Factory returned")
        let unblock = DispatchSemaphore(value: 0)
        let pipeline = VoiceRecognitionPipeline { _ in
            loading.fulfill()
            _ = unblock.wait(timeout: .now() + 5)
            returned.fulfill()
            return StubRecognizer()
        }
        pipeline.onStreamingReady = { _ in XCTFail("Cancelled load must not announce ready") }
        pipeline.onFinished = { _ in XCTFail("Cancelled load must not finish a dictation") }
        pipeline.begin(dictationID: "cancel")
        pipeline.load(streaming: configuration)
        await fulfillment(of: [loading], timeout: 2)
        pipeline.cancel()
        unblock.signal()
        await fulfillment(of: [returned], timeout: 2)
        pipeline.unload()
    }
}

private final class StubRecognizer: VoiceStreamingRecognizing, @unchecked Sendable {
    var text: String { "পরীক্ষা" }
    var isEndpoint: Bool { false }
    func accept(_ samples: UnsafeBufferPointer<Float>) {}
    func reset() {}
    func finishPhrase() -> String { text }
}
