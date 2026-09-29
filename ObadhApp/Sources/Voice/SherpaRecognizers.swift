import Foundation
import SherpaOnnxC

/// Thin Swift owners for the sherpa-onnx C API. Neither class is thread-safe: each is
/// created, fed, and destroyed on one serial queue owned by `VoiceRecognitionPipeline`.
///
/// Config strings are `strdup`ed for the duration of the create call only; sherpa-onnx
/// copies them into its own C++ config, so nothing dangles afterwards.
private final class CStrings {
    private var pointers: [UnsafeMutablePointer<CChar>] = []

    func make(_ string: String) -> UnsafePointer<CChar> {
        let pointer = strdup(string)!
        pointers.append(pointer)
        return UnsafePointer(pointer)
    }

    deinit {
        pointers.forEach { free($0) }
    }
}

enum SherpaError: Error {
    case couldNotCreate(String)
}

/// First pass: streaming transducer. Audio in, growing partial text out, with the
/// model's own endpointing to close a phrase on a pause.
final class SherpaStreamingRecognizer: @unchecked Sendable {
    private let recognizer: OpaquePointer
    private var stream: OpaquePointer

    struct Paths {
        let encoder: URL, decoder: URL, joiner: URL, tokens: URL
        let modelType: String
    }

    /// `trailingSilence` is how long a pause (after speech) closes a phrase. Short
    /// enough to feel responsive, long enough not to split a sentence at a breath.
    init(paths: Paths, trailingSilence: Float = 0.9, threads: Int32 = 2) throws {
        let strings = CStrings()
        var config = SherpaOnnxOnlineRecognizerConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = strings.make(paths.encoder.path)
        config.model_config.transducer.decoder = strings.make(paths.decoder.path)
        config.model_config.transducer.joiner = strings.make(paths.joiner.path)
        config.model_config.tokens = strings.make(paths.tokens.path)
        config.model_config.num_threads = threads
        config.model_config.provider = strings.make("cpu")
        config.model_config.model_type = strings.make(paths.modelType)
        config.model_config.debug = 0
        // Greedy, not beam search: beam search revises words it has already shown
        // (measured on SUBAK.KO: 1.7 rewrites and ~33 characters retyped per minute,
        // which reads as jitter in the text field). Greedy never revises a shown
        // word and costs 0.5 WER points.
        config.decoding_method = strings.make("greedy_search")
        config.max_active_paths = 4
        config.enable_endpoint = 1
        config.rule1_min_trailing_silence = 2.4
        config.rule2_min_trailing_silence = trailingSilence
        config.rule3_min_utterance_length = 25
        guard let recognizer = SherpaOnnxCreateOnlineRecognizer(&config) else {
            throw SherpaError.couldNotCreate("online recognizer")
        }
        guard let stream = SherpaOnnxCreateOnlineStream(recognizer) else {
            SherpaOnnxDestroyOnlineRecognizer(recognizer)
            throw SherpaError.couldNotCreate("online stream")
        }
        self.recognizer = recognizer
        self.stream = stream
    }

    deinit {
        SherpaOnnxDestroyOnlineStream(stream)
        SherpaOnnxDestroyOnlineRecognizer(recognizer)
    }

    /// Feed 16 kHz mono samples and decode whatever is ready.
    func accept(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, base, Int32(samples.count))
        while SherpaOnnxIsOnlineStreamReady(recognizer, stream) == 1 {
            SherpaOnnxDecodeOnlineStream(recognizer, stream)
        }
    }

    var text: String {
        guard let result = SherpaOnnxGetOnlineStreamResult(recognizer, stream) else { return "" }
        defer { SherpaOnnxDestroyOnlineRecognizerResult(result) }
        guard let cText = result.pointee.text else { return "" }
        return String(cString: cText).trimmingCharacters(in: .whitespaces)
    }

    var isEndpoint: Bool {
        SherpaOnnxOnlineStreamIsEndpoint(recognizer, stream) == 1
    }

    /// Flush the tail (so the last word is not cut off) and return the final text.
    func finishPhrase() -> String {
        var tail = [Float](repeating: 0, count: 4_800)  // 0.3 s of silence
        tail.withUnsafeBufferPointer { accept($0) }
        return text
    }

    /// Start a new phrase; the model state carries no text across.
    func reset() {
        SherpaOnnxOnlineStreamReset(recognizer, stream)
    }
}

/// Second pass: a non-autoregressive CTC model that re-reads a finished phrase in
/// one shot. No token-by-token decoding, so its cost is the encoder alone.
final class SherpaPhraseRecognizer: @unchecked Sendable {
    private let recognizer: OpaquePointer

    init(model: URL, tokens: URL, threads: Int32 = 2) throws {
        let strings = CStrings()
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        config.model_config.nemo_ctc.model = strings.make(model.path)
        config.model_config.tokens = strings.make(tokens.path)
        config.model_config.num_threads = threads
        config.model_config.provider = strings.make("cpu")
        config.model_config.debug = 0
        config.decoding_method = strings.make("greedy_search")
        guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&config) else {
            throw SherpaError.couldNotCreate("offline recognizer")
        }
        self.recognizer = recognizer
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
    }

    func transcribe(_ samples: [Float]) -> String {
        guard !samples.isEmpty, let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return "" }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxAcceptWaveformOffline(stream, 16_000, buffer.baseAddress, Int32(buffer.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return "" }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        guard let cText = result.pointee.text else { return "" }
        return String(cString: cText).trimmingCharacters(in: .whitespaces)
    }
}
