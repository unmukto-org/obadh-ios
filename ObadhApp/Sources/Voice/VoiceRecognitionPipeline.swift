import Foundation
import os

/// Two-pass recognition for one warm session.
///
///     16 kHz audio ─▶ streaming recognizer ─▶ draft text (every buffer)
///                  └▶ phrase buffer ─(pause)─▶ refiner ─▶ settled text
///
/// Threading: everything about the current phrase lives on `streamQueue`. The refiner
/// runs on its own serial `refineQueue`, so a slow re-read never delays the draft of
/// the next phrase, and phrases settle strictly in order (the keyboard relies on
/// that; see VoiceDraftReconciler).
final class VoiceRecognitionPipeline: @unchecked Sendable {
    struct StreamingConfiguration {
        let paths: SherpaStreamingRecognizer.Paths
    }

    struct RefinerConfiguration {
        let model: URL
        let tokens: URL
        let guardRatio: Double
    }

    /// Called on `streamQueue` whenever the transcript changes.
    var onSegments: (@Sendable (_ dictationID: String, _ segments: [VoiceSegment], _ hearsSpeech: Bool) -> Void)?
    /// Called on `streamQueue` once a finish has settled every phrase.
    var onFinished: (@Sendable (_ dictationID: String) -> Void)?

    private let log = Logger(subsystem: "org.unmukto.obadh", category: "voice")
    private let streamQueue = DispatchQueue(label: "org.unmukto.obadh.voice.stream", qos: .userInteractive)
    private let refineQueue = DispatchQueue(label: "org.unmukto.obadh.voice.refine", qos: .userInitiated)

    // streamQueue state
    private var streaming: SherpaStreamingRecognizer?
    private var refiner: SherpaPhraseRecognizer?
    private var guardRatio = VoicePhraseArbiter.defaultGuardRatio
    private var dictationID: String?
    private var segments: [VoiceSegment] = []
    private var nextSegmentID = 0
    private var phraseAudio: [Float] = []
    /// Audio that arrived while the streaming model was still loading. Capped: the
    /// model loads in well under a second, this is only a safety net.
    private var backlog: [Float] = []
    private static let backlogLimit = 16_000 * 20
    private var pendingRefinements = 0
    private var finishRequested = false

    // MARK: Loading

    /// Loads the models off the main thread. The streaming model comes first because
    /// it is what the user sees; the refiner follows and is used from the next phrase.
    func load(streaming: StreamingConfiguration, refiner: RefinerConfiguration?) {
        streamQueue.async { [self] in
            let start = CFAbsoluteTimeGetCurrent()
            do {
                self.streaming = try SherpaStreamingRecognizer(paths: streaming.paths)
                log.notice("OBADH-VOICE streaming model loaded in \(CFAbsoluteTimeGetCurrent() - start, privacy: .public)s")
            } catch {
                log.error("OBADH-VOICE streaming model failed: \(String(describing: error), privacy: .public)")
            }
            if !backlog.isEmpty {
                let pending = backlog
                backlog.removeAll()
                pending.withUnsafeBufferPointer { process($0) }
            }
        }
        guard let refiner else { return }
        refineQueue.async { [self] in
            let start = CFAbsoluteTimeGetCurrent()
            do {
                let recognizer = try SherpaPhraseRecognizer(model: refiner.model, tokens: refiner.tokens)
                log.notice("OBADH-VOICE refiner loaded in \(CFAbsoluteTimeGetCurrent() - start, privacy: .public)s")
                streamQueue.async {
                    self.refiner = recognizer
                    self.guardRatio = refiner.guardRatio
                }
            } catch {
                log.error("OBADH-VOICE refiner failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    var isStreamingLoaded: Bool {
        streamQueue.sync { streaming != nil }
    }

    // MARK: Dictation

    func begin(dictationID: String) {
        streamQueue.async { [self] in
            self.dictationID = dictationID
            segments = []
            phraseAudio = []
            backlog = []
            finishRequested = false
            streaming?.reset()
            publish(hearsSpeech: false)
        }
    }

    /// Feed converted audio. Ignored unless dictating: while the session is merely
    /// warm, every buffer is dropped here, never stored or recognized.
    func append(_ samples: [Float]) {
        streamQueue.async { [self] in
            guard dictationID != nil, !finishRequested else { return }
            guard streaming != nil else {
                backlog.append(contentsOf: samples)
                if backlog.count > Self.backlogLimit {
                    backlog.removeFirst(backlog.count - Self.backlogLimit)
                }
                return
            }
            samples.withUnsafeBufferPointer { process($0) }
        }
    }

    /// Close the open phrase and settle everything, then call `onFinished`.
    func finish() {
        streamQueue.async { [self] in
            guard dictationID != nil, !finishRequested else { return }
            finishRequested = true
            closePhrase(force: true)
            completeFinishIfSettled()
        }
    }

    func cancel() {
        streamQueue.async { [self] in
            dictationID = nil
            segments = []
            phraseAudio = []
            backlog = []
            finishRequested = false
            streaming?.reset()
        }
    }

    // MARK: streamQueue internals

    private func process(_ samples: UnsafeBufferPointer<Float>) {
        guard let streaming else { return }
        phraseAudio.append(contentsOf: samples)
        streaming.accept(samples)
        let text = streaming.text
        updateOpenSegment(text: text)
        if streaming.isEndpoint {
            closePhrase(force: false)
        }
    }

    private func updateOpenSegment(text: String) {
        let normalized = VoicePhraseArbiter.normalize(text)
        if let last = segments.last, !last.isSettled, last.id == nextSegmentID {
            guard last.text != normalized else { return }
            segments[segments.count - 1].text = normalized
        } else {
            guard !normalized.isEmpty else { return }
            segments.append(VoiceSegment(id: nextSegmentID, text: normalized, isSettled: false))
        }
        publish(hearsSpeech: true)
    }

    private func closePhrase(force: Bool) {
        guard let streaming else { return }
        let draft = VoicePhraseArbiter.normalize(streaming.finishPhrase())
        let audio = phraseAudio
        phraseAudio = []
        streaming.reset()
        guard !draft.isEmpty else {
            // Silence or noise: nothing was said, so the audio is simply dropped.
            if let index = segments.lastIndex(where: { $0.id == nextSegmentID }) {
                segments.remove(at: index)
                publish(hearsSpeech: false)
            }
            return
        }
        let id = nextSegmentID
        nextSegmentID += 1
        if let index = segments.lastIndex(where: { $0.id == id }) {
            segments[index].text = draft
        } else {
            segments.append(VoiceSegment(id: id, text: draft, isSettled: false))
        }
        guard let refiner else {
            settle(id: id, text: draft)
            return
        }
        pendingRefinements += 1
        let guardRatio = self.guardRatio
        let dictation = dictationID
        refineQueue.async { [self] in
            let start = CFAbsoluteTimeGetCurrent()
            let reading = refiner.transcribe(audio)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            log.notice("OBADH-VOICE refined \(Double(audio.count) / 16_000, privacy: .public)s phrase in \(elapsed, privacy: .public)s")
            streamQueue.async {
                self.pendingRefinements -= 1
                guard self.dictationID == dictation else { return }
                self.settle(id: id, text: VoicePhraseArbiter.choose(streaming: draft, refined: reading, guardRatio: guardRatio))
                self.completeFinishIfSettled()
            }
        }
        publish(hearsSpeech: true)
    }

    private func settle(id: Int, text: String) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].text = text
        segments[index].isSettled = true
        publish(hearsSpeech: true)
    }

    private func completeFinishIfSettled() {
        guard finishRequested, pendingRefinements == 0, let dictationID else { return }
        onFinished?(dictationID)
    }

    private func publish(hearsSpeech: Bool) {
        guard let dictationID else { return }
        onSegments?(dictationID, segments, hearsSpeech)
    }
}
