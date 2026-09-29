import Foundation
import os

/// Recognition for one voice session.
///
///     microphone ─▶ VoiceAudioRing ─▶ worker (own cursor) ─▶ streaming recognizer
///                                                            └▶ VoiceTranscriptBuilder
///                                                                 (committed | tentative)
///
/// The microphone only ever writes into the ring and never waits on anything. The
/// worker reads from its own cursor at its own pace. A dictation is a span of ring
/// positions: it starts `preRoll` before the tap and ends `postRoll` after Done, so
/// the first and last syllables are never chopped, and audio that arrives while the
/// model is still loading is simply read once it has loaded. The recognizer runs
/// continuously through a dictation, never reset at a pause: a pause only commits
/// the words so far. (A freshly reset stream intermittently swallowed the first word
/// after it.) Only a very long dictation is reset, at a pause, to bound its cost.
///
/// Threading: all recognition state lives on `queue`. `append` may be called from
/// the audio thread; it only writes to the ring and schedules a pump.
final class VoiceRecognitionPipeline: @unchecked Sendable {
    struct StreamingConfiguration {
        let paths: SherpaStreamingRecognizer.Paths
    }

    /// Called on `queue` whenever the transcript changes.
    var onTranscript: (@Sendable (_ dictationID: String, _ transcript: VoiceTranscript) -> Void)?
    /// Called on `queue` when the streaming model finishes loading (true) or fails.
    var onStreamingReady: (@Sendable (Bool) -> Void)?
    /// Called on `queue` once a finished dictation's last audio has been recognized.
    var onFinished: (@Sendable (_ dictationID: String) -> Void)?
    /// Called on `queue`, at most four times a second, while the audio holds voice.
    var onVoiceActivity: (@Sendable () -> Void)?

    /// Audio kept from before the tap: the first syllable often starts with it.
    static let preRollSamples = 16_000 * 35 / 100
    /// Audio still taken after Done: the last syllable often ends after it.
    static let postRollSamples = 16_000 * 45 / 100
    /// While not dictating, only this much audio is kept (enough for pre-roll).
    static let idleRetainedSamples = 16_000

    private let log = Logger(subsystem: "org.unmukto.obadh", category: "voice")
    private let queue = DispatchQueue(label: "org.unmukto.obadh.voice.recognition", qos: .userInteractive)
    let ring = VoiceAudioRing(seconds: 60)
    /// Coalescing event source: any number of audio arrivals between two runs of the
    /// worker become one wake-up.
    private lazy var wakeup: DispatchSourceUserDataAdd = {
        let source = DispatchSource.makeUserDataAddSource(queue: queue)
        source.setEventHandler { [weak self] in self?.pump() }
        source.activate()
        return source
    }()
    private let pumpLock = NSLock()
    /// Set the instant a dictation is requested (under `pumpLock`): audio from here
    /// on is never trimmed, even if the queue is still busy loading the model.
    private var armedFrom: Int64?

    // queue state
    private var streaming: SherpaStreamingRecognizer?
    private var dictationID: String?
    private var cursor: Int64 = 0
    private var stopAt: Int64?
    private var builder = VoiceTranscriptBuilder()
    private var lastHypothesis = ""
    private var lastPublished = VoiceTranscript.empty
    private var noiseFloor: Float = 0.004
    private var lastVoiceReport: CFAbsoluteTime = 0
    /// Hysteresis: voice starts above `onsetFactor` × floor and continues until the
    /// level drops below `offsetFactor` × floor for the hangover.
    private var inVoice = false
    private var belowOffsetSince: CFAbsoluteTime = 0
    private static let onsetFactor: Float = 3.2
    private static let offsetFactor: Float = 1.8
    private static let hangover: CFAbsoluteTime = 0.3
    // Health counters, logged once a second while dictating (never any text).
    private var statSamples = 0
    private var statPeak: Float = 0
    private var statSince = CFAbsoluteTimeGetCurrent()

    // MARK: Loading

    func load(streaming configuration: StreamingConfiguration) {
        queue.async { [self] in
            let start = CFAbsoluteTimeGetCurrent()
            do {
                streaming = try SherpaStreamingRecognizer(paths: configuration.paths)
                log.notice("OBADH-VOICE streaming model loaded in \(CFAbsoluteTimeGetCurrent() - start, privacy: .public)s")
                onStreamingReady?(true)
                pump()
            } catch {
                log.error("OBADH-VOICE streaming model failed: \(String(describing: error), privacy: .public)")
                onStreamingReady?(false)
            }
        }
    }

    /// Frees the model and forgets all audio (the session ended).
    func unload() {
        queue.async { [self] in
            streaming = nil
            dictationID = nil
            stopAt = nil
            ring.reset()
        }
    }

    // MARK: Audio in

    /// Audio thread: store, then let the worker catch up. Never blocks on recognition.
    func append(_ samples: UnsafeBufferPointer<Float>) {
        ring.write(samples)
        wakeup.add(data: 1)
    }

    func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    // MARK: Dictation

    /// The start position is taken now, when the dictation is requested, not when the
    /// queue gets to it: the queue may be busy loading the model, and everything said
    /// meanwhile belongs to this dictation.
    func begin(dictationID: String) {
        let start = max(ring.oldestIndex, ring.writeIndex - Int64(Self.preRollSamples))
        pumpLock.lock()
        armedFrom = start
        pumpLock.unlock()
        queue.async { [self] in
            self.dictationID = dictationID
            cursor = start
            pumpLock.lock()
            armedFrom = nil
            pumpLock.unlock()
            stopAt = nil
            builder = VoiceTranscriptBuilder()
            lastHypothesis = ""
            lastPublished = .empty
            streaming?.reset()
            publish(force: true)
            pump()
        }
    }

    /// Take `postRoll` more audio, recognize everything up to there, then finish.
    /// The end position, like the start, is taken when requested. Without post-roll
    /// it ends at the audio already captured (the microphone is about to stop).
    func finish(postRoll: Bool = true) {
        let end = ring.writeIndex + (postRoll ? Int64(Self.postRollSamples) : 0)
        queue.async { [self] in
            guard dictationID != nil, stopAt == nil else { return }
            stopAt = end
            pump()
        }
    }

    func cancel() {
        pumpLock.lock()
        armedFrom = nil
        pumpLock.unlock()
        queue.async { [self] in
            dictationID = nil
            stopAt = nil
            builder = VoiceTranscriptBuilder()
            streaming?.reset()
        }
    }

    // MARK: Worker

    /// Recognize everything between the cursor and what the ring holds (or the
    /// dictation's end), in 100 ms steps.
    private func pump() {
        guard let dictationID else {
            // Not dictating: keep only the last moment, for the next pre-roll, and
            // never anything a just-requested dictation starts from.
            pumpLock.lock()
            let armed = armedFrom
            pumpLock.unlock()
            ring.discard(before: min(ring.writeIndex - Int64(Self.idleRetainedSamples), armed ?? .max))
            return
        }
        guard let streaming else { return }   // still loading: the ring holds the audio
        let limit = min(stopAt ?? .max, ring.writeIndex)
        while cursor < limit {
            let read = ring.read(from: cursor, maxCount: min(1_600, Int(limit - cursor)))
            guard !read.samples.isEmpty else { break }
            cursor = read.next
            read.samples.withUnsafeBufferPointer { streaming.accept($0) }
            detectVoice(read.samples)
            recordHealth(read.samples)
            let hypothesis = streaming.text
            if hypothesis != lastHypothesis {
                lastHypothesis = hypothesis
                builder.setOpenPhrase(hypothesis)
            }
            if streaming.isEndpoint {
                // A pause: commit everything so far; the stream keeps its context.
                builder.commitAll()
                if hypothesis.count > Self.resetAfterCharacters {
                    closePhrase(streaming)
                }
            }
            publish(force: false)
        }
        if let stopAt, cursor >= stopAt {
            builder.closeOpenPhrase(final: streaming.finishPhrase())
            builder.finish()
            publish(force: true)
            self.dictationID = nil
            self.stopAt = nil
            streaming.reset()
            onFinished?(dictationID)
        }
    }

    /// Past this much text, a pause also resets the stream (its decoding state grows
    /// with the dictation). Dictations rarely get here.
    static let resetAfterCharacters = 600

    /// The stream is reset at a pause: the phrase is committed in full, and the fresh
    /// stream is primed with the audio just before, so it does not start cold.
    private func closePhrase(_ streaming: SherpaStreamingRecognizer) {
        builder.closeOpenPhrase(final: streaming.finishPhrase())
        lastHypothesis = ""
        streaming.reset()
        let primer = ring.read(from: cursor - 4_000, maxCount: 4_000)
        primer.samples.withUnsafeBufferPointer { streaming.accept($0) }
        publish(force: true)
    }

    private func publish(force: Bool) {
        guard let dictationID else { return }
        let transcript = builder.transcript
        guard force || transcript != lastPublished else { return }
        lastPublished = transcript
        onTranscript?(dictationID, transcript)
    }

    /// Voice activity detection: energy against an adaptive noise floor, with
    /// hysteresis (separate onset and offset thresholds, plus a hangover) so a word's
    /// quiet ending is not cut off and room noise does not flicker in and out.
    /// Silence detection runs on this, not on recognized text, so a quiet or unclear
    /// word never ends a dictation.
    private func detectVoice(_ samples: [Float]) {
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(max(samples.count, 1))).squareRoot()
        // The floor falls quickly toward quiet and rises slowly, so speech never
        // becomes the floor; it is not adapted while voice is present.
        if !inVoice || rms < noiseFloor {
            noiseFloor += (rms - noiseFloor) * (rms < noiseFloor ? 0.25 : 0.003)
        }
        let now = CFAbsoluteTimeGetCurrent()
        if rms > max(noiseFloor * Self.onsetFactor, 0.006) {
            inVoice = true
            belowOffsetSince = 0
        } else if inVoice, rms < noiseFloor * Self.offsetFactor {
            if belowOffsetSince == 0 { belowOffsetSince = now }
            if now - belowOffsetSince > Self.hangover { inVoice = false }
        }
        guard inVoice, now - lastVoiceReport > 0.25 else { return }
        lastVoiceReport = now
        onVoiceActivity?()
    }

    /// Once a second while dictating: how much audio arrived and how far recognition
    /// runs behind the microphone. Never the text itself.
    private func recordHealth(_ samples: [Float]) {
        statSamples += samples.count
        for sample in samples where abs(sample) > statPeak { statPeak = abs(sample) }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - statSince >= 1 else { return }
        let lagMs = Double(ring.writeIndex - cursor) / 16
        log.notice("OBADH-VOICE health: \(self.statSamples, privacy: .public) samples, peak \(String(format: "%.3f", self.statPeak), privacy: .public), lag \(Int(lagMs), privacy: .public) ms, \(self.lastPublished.text.count, privacy: .public) chars (\(self.lastPublished.stableLength, privacy: .public) committed)")
        statSamples = 0
        statPeak = 0
        statSince = now
    }
}
