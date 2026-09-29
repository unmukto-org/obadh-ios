#if DEBUG
import AVFoundation
import Foundation
import os

/// DEBUG-only hooks for exercising voice typing on the Simulator, which has no
/// scriptable microphone or taps:
///
/// * `--voice-download-defaults` downloads the default models through the real
///   downloader (network, checksums, staging, install).
/// * `--voice-selftest=<path to wav>` streams a recording through the full two-pass
///   pipeline at 4x real time and logs every draft and settled phrase.
///
/// Watch with: `xcrun simctl spawn booted log stream --predicate 'eventMessage CONTAINS "OBADH-VOICE"'`
@MainActor
enum VoiceSelfTest {
    nonisolated private static let log = Logger(subsystem: "org.unmukto.obadh", category: "voice")
    private static var retained: [AnyObject] = []

    static func runIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--voice-download-defaults") {
            let library = VoiceModelLibrary.shared
            log.notice("OBADH-VOICE selftest: downloading \(library.defaultSetDownloadBytes, privacy: .public) bytes")
            library.downloadDefaultSet()
            let token = library.$states.sink { states in
                let summary = states.map { "\($0.key)=\(String(describing: $0.value))" }.sorted().joined(separator: " ")
                log.notice("OBADH-VOICE selftest models: \(summary, privacy: .public)")
            }
            retained.append(token as AnyObject)
        }
        let prefix = "--voice-selftest="
        guard let argument = arguments.first(where: { $0.hasPrefix(prefix) }) else { return }
        let path = String(argument.dropFirst(prefix.count))
        Task.detached { await run(path: path) }
    }

    nonisolated private static func run(path: String) async {
        let (streaming, refiner) = await MainActor.run {
            (VoiceModelLibrary.shared.activeStreamingConfiguration(), VoiceModelLibrary.shared.activeRefinerConfiguration())
        }
        guard let streaming else {
            log.error("OBADH-VOICE selftest: no streaming model installed")
            return
        }
        guard let samples = loadMono16k(path) else {
            log.error("OBADH-VOICE selftest: cannot read \(path, privacy: .public)")
            return
        }
        let pipeline = VoiceRecognitionPipeline()
        let finished = AsyncStream<Void>.makeStream()
        pipeline.onSegments = { _, segments, _ in
            let rendered = segments.map { "\($0.isSettled ? "✓" : "…")\($0.id):\($0.text)" }.joined(separator: " | ")
            log.notice("OBADH-VOICE selftest segments: \(rendered, privacy: .public)")
        }
        pipeline.onFinished = { _ in finished.continuation.yield() }
        let start = CFAbsoluteTimeGetCurrent()
        pipeline.load(streaming: streaming, refiner: refiner)
        pipeline.begin(dictationID: "selftest")
        let chunk = 800  // 50 ms
        for offset in stride(from: 0, to: samples.count, by: chunk) {
            pipeline.append(Array(samples[offset..<min(offset + chunk, samples.count)]))
            try? await Task.sleep(nanoseconds: 12_500_000)  // 4x real time
        }
        pipeline.finish()
        for await _ in finished.stream { break }
        let audio = Double(samples.count) / 16_000
        log.notice("OBADH-VOICE selftest done: \(audio, privacy: .public)s audio in \(CFAbsoluteTimeGetCurrent() - start, privacy: .public)s")
    }

    nonisolated private static func loadMono16k(_ path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil else { return nil }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / file.processingFormat.sampleRate + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        _ = converter.convert(to: output, error: nil) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
#endif
