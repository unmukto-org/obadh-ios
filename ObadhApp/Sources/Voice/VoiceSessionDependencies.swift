import Foundation

/// Hardware/recognition boundaries, injectable in lifecycle tests without a mic
/// or model download. Production uses the same controller and callback paths.
protocol VoiceAudioCapturing: AnyObject {
    var isMetering: Bool { get set }
    var hasDelivered: Bool { get }
    var lastBufferAt: CFTimeInterval { get }
    var onSamples: (@Sendable (UnsafeBufferPointer<Float>) -> Void)? { get set }
    var onFailure: (@Sendable (Error) -> Void)? { get set }
    func start() throws
    func restart() throws
    func stop()
}

protocol VoiceRecognizing: AnyObject, Sendable {
    var onTranscript: (@Sendable (String, VoiceTranscript) -> Void)? { get set }
    var onStreamingReady: (@Sendable (Bool) -> Void)? { get set }
    var onFinished: (@Sendable (String) -> Void)? { get set }
    var onVoiceActivity: (@Sendable () -> Void)? { get set }
    var onFailure: (@Sendable (String, VoiceSessionFailure) -> Void)? { get set }
    func load(streaming: VoiceRecognitionPipeline.StreamingConfiguration)
    func begin(dictationID: String)
    func append(_ samples: UnsafeBufferPointer<Float>)
    func finish(postRoll: Bool)
    func cancel()
    func unload()
}

extension VoiceAudioCapture: VoiceAudioCapturing {}
extension VoiceRecognitionPipeline: VoiceRecognizing {}

protocol VoiceStreamingRecognizing: AnyObject, Sendable {
    var text: String { get }
    var isEndpoint: Bool { get }
    func accept(_ samples: UnsafeBufferPointer<Float>)
    func reset()
    func finishPhrase() -> String
}

extension SherpaStreamingRecognizer: VoiceStreamingRecognizing {}
