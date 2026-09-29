import AVFoundation
import Combine
import UIKit
import os

/// The app side of voice typing, one dictation at a time.
///
///     keyboard mic ─▶ Obadh voice screen, already listening
///                      │  speak (text appears on this screen)
///                      ▼  Done, a long pause, or leaving the screen
///                    finishing ─▶ final text; microphone released at once
///                      │
///     keyboard ◀───────┘  on ◀ Back: the keyboard inserts the final text and
///                         acknowledges; the text is then forgotten here
///
/// The microphone runs only while the voice screen is in front. There is no warm
/// session, no background recording, and no indicator between dictations. While
/// dictating nothing crosses to the keyboard: the text is shown on this screen and
/// handed over once, when it is final.
@MainActor
final class VoiceSessionController: ObservableObject {
    static let shared = VoiceSessionController()

    @Published private(set) var phase: VoiceSessionPhase = .idle {
        didSet {
            guard phase != oldValue else { return }
            log.notice("OBADH-VOICE phase \(oldValue.rawValue, privacy: .public) -> \(self.phase.rawValue, privacy: .public)")
        }
    }
    /// Audio buffers are arriving right now (watchdog-measured, not assumed).
    @Published private(set) var isAudioFlowing = false
    @Published private(set) var transcript = VoiceTranscript.empty
    @Published private(set) var failure: VoiceSessionFailure?
    @Published private(set) var dictationID: String?

    /// The finished text is waiting for the keyboard to insert it.
    var hasFinalText: Bool { transcript.isFinal && dictationID != nil }

    let levels = VoiceLevelFeed()

    private let log = Logger(subsystem: "org.unmukto.obadh", category: "voice")
    private let models: VoiceModelLibrary
    private let directory: URL?
    private let levelWriter: VoiceLevelWriter?
    private let capture: VoiceAudioCapture
    private let pipeline = VoiceRecognitionPipeline()
    private var commandObserver: VoiceDarwinObserver?
    private var watchdogTimer: Timer?
    /// When the audio last held voice (a quiet or unclear word must not end a
    /// dictation, so this is voice activity, not recognized text).
    private var lastVoiceAt: CFTimeInterval = 0
    private var snapshotSeq: UInt64 = 0
    private var lastCommandSeq: UInt64 = 0
    private var notificationTokens: [NSObjectProtocol] = []
    /// The one start in flight: a cold launch may deliver the URL more than once.
    private var bringUp: Task<Bool, Never>?
    private var recoveryAttempted = false
    /// Keeps the app running long enough to finish a dictation the user left mid-way.
    private var finishingTask: UIBackgroundTaskIdentifier = .invalid
    /// Buffers arrive every ~50 ms; this long without one means the engine stalled.
    private static let audioStallThreshold: CFTimeInterval = 0.8
    /// How long a freshly started engine may take to deliver its first buffer.
    private static let audioStartThreshold: CFTimeInterval = 3

    private init(models: VoiceModelLibrary = .shared) {
        self.models = models
        directory = VoiceSessionChannel.directory()
        levelWriter = directory.flatMap { VoiceLevelWriter(url: VoiceSessionChannel.levelsURL(in: $0)) }
        capture = VoiceAudioCapture(levelWriter: levelWriter)
        levels.attach(directory.map(VoiceSessionChannel.levelsURL(in:)))
        snapshotSeq = UInt64(Date().timeIntervalSince1970 * 1000)
        wirePipeline()
        observeCommands()
        observeLifecycle()
    }

    // MARK: Entry points

    /// The keyboard opened `obadh://voice?d=<id>`: start dictating at once.
    func handleVoiceURL(_ url: URL) {
        guard let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == VoiceSessionChannel.dictationQueryItem })?.value else { return }
        Task { await startDictation(id) }
    }

    func startDictation(_ id: String) async {
        if dictationID == id, phase != .idle { return }
        if phase != .idle { release() }
        let task: Task<Bool, Never>
        if let bringUp {
            task = bringUp
        } else {
            task = Task { await self.performBringUp() }
            bringUp = task
        }
        let started = await task.value
        bringUp = nil
        guard started else { return }
        dictationID = id
        transcript = .empty
        phase = .listening
        capture.isMetering = true
        pipeline.begin(dictationID: id)
        lastVoiceAt = CACurrentMediaTime()
        publishNow()
    }

    private func performBringUp() async -> Bool {
        failure = nil
        phase = .starting
        guard await ensureMicrophonePermission() else {
            fail(.microphonePermissionDenied)
            return false
        }
        guard let streaming = models.activeStreamingConfiguration() else {
            fail(.noStreamingModel)
            return false
        }
        do {
            try configureAudioSession()
            try capture.start()
        } catch {
            log.error("OBADH-VOICE audio start failed: \(String(describing: error), privacy: .public)")
            fail(.audioEngineFailed)
            return false
        }
        // Audio flows into the ring before the model has loaded; recognition catches
        // up from there, so nothing said during the load is lost.
        pipeline.load(streaming: streaming)
        recoveryAttempted = false
        startWatchdog()
        return true
    }

    /// Done: take the last moment of audio, recognize it, then release the mic.
    /// `postRoll` is off when the microphone is about to stop anyway (leaving the
    /// screen, a call): the dictation then ends at what was already heard.
    func finishDictation(postRoll: Bool = true) {
        guard phase == .listening else { return }
        phase = .finishing
        capture.isMetering = false
        pipeline.finish(postRoll: postRoll)
    }

    /// Cancel: nothing is kept or inserted.
    func cancelDictation() {
        pipeline.cancel()
        release()
        dictationID = nil
        transcript = .empty
        publishNow()
    }

    /// Microphone off, model unloaded, all audio forgotten. The final text (if any)
    /// stays until the keyboard has inserted it.
    private func release() {
        pipeline.unload()
        capture.isMetering = false
        capture.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        isAudioFlowing = false
        phase = .idle
        endFinishingTask()
    }

    // MARK: Pipeline

    private func wirePipeline() {
        pipeline.onTranscript = { [weak self] id, transcript in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.dictationID == id else { return }
                    // Shown on the voice screen directly; nothing crosses to the
                    // keyboard until the text is final.
                    self.transcript = transcript
                }
            }
        }
        pipeline.onVoiceActivity = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.lastVoiceAt = CACurrentMediaTime() }
            }
        }
        pipeline.onFinished = { [weak self] id in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.dictationID == id else { return }
                    self.release()
                    self.log.notice("OBADH-VOICE dictation final: \(self.transcript.text.count, privacy: .public) chars; microphone released")
                    self.publishNow()
                }
            }
        }
        pipeline.onStreamingReady = { [weak self] ready in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !ready, self.phase != .idle else { return }
                    self.fail(.noStreamingModel)
                }
            }
        }
        capture.onSamples = { [pipeline] samples in
            pipeline.append(samples)
        }
        capture.onFailure = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.fail(.audioEngineFailed) }
            }
        }
    }

    // MARK: The keyboard's side

    private func observeCommands() {
        commandObserver = VoiceDarwinObserver(name: VoiceSessionChannel.commandDarwinName) { [weak self] in
            self?.readCommand()
        }
    }

    private func readCommand() {
        guard let directory,
              let command = VoiceMessageFile.read(VoiceCommand.self, from: VoiceSessionChannel.commandURL(in: directory)),
              command.seq > lastCommandSeq else { return }
        lastCommandSeq = command.seq
        guard Date().timeIntervalSince(command.issuedAt) < 60 else { return }
        log.notice("OBADH-VOICE command \(command.kind.rawValue, privacy: .public)")
        switch command.kind {
        case .acknowledge:
            // Inserted: the text is forgotten here.
            guard dictationID == command.dictationID else { return }
            dictationID = nil
            transcript = .empty
            publishNow()
        case .cancel:
            if dictationID == command.dictationID { cancelDictation() }
        case .start, .stop, .endSession:
            break
        }
    }

    /// The snapshot is written only when something the keyboard needs changes: a
    /// dictation starts (so a returning keyboard knows to wait), or its final text is
    /// ready. Never per partial.
    private func publishNow() {
        guard let directory else { return }
        snapshotSeq += 1
        let snapshot = VoiceSessionSnapshot(
            seq: snapshotSeq,
            phase: phase,
            heartbeat: Date(),
            dictationID: dictationID,
            transcript: transcript.isFinal ? transcript : .empty,
            failure: failure,
            isAudioFlowing: isAudioFlowing,
            isRecognizerReady: nil
        )
        do {
            try VoiceMessageFile.write(snapshot, to: VoiceSessionChannel.snapshotURL(in: directory))
            VoiceDarwinNotifier.post(VoiceSessionChannel.snapshotDarwinName)
        } catch {
            log.error("OBADH-VOICE snapshot write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Watchdog

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func tick() {
        guard phase == .listening else { return }
        let now = CACurrentMediaTime()
        if now - lastVoiceAt > VoiceSessionTiming.silenceEndsDictation {
            log.notice("OBADH-VOICE silence ended the dictation")
            finishDictation()
            return
        }
        let delivered = capture.hasDelivered
        let silentFor = now - capture.lastBufferAt
        if !delivered, silentFor < Self.audioStartThreshold { return }
        let flowing = delivered && silentFor < Self.audioStallThreshold
        if flowing != isAudioFlowing {
            isAudioFlowing = flowing
            log.notice("OBADH-VOICE audio \(flowing ? "flowing" : "stalled", privacy: .public)")
        }
        if flowing {
            recoveryAttempted = false
            return
        }
        guard !recoveryAttempted else {
            fail(.audioEngineFailed)
            return
        }
        recoveryAttempted = true
        do {
            try capture.restart()
            log.notice("OBADH-VOICE capture rebuilt after a stall")
        } catch {
            fail(.audioEngineFailed)
        }
    }

    // MARK: Audio session and app lifecycle

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // Mix with others: dictating must not stop the user's music or podcast.
        var options: AVAudioSession.CategoryOptions = [.mixWithOthers, .defaultToSpeaker]
        if #available(iOS 26.0, *) {
            options.insert(.allowBluetoothHFP)
        } else {
            options.insert(.allowBluetooth)
        }
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        // Leaving the voice screen mid-dictation (◀ Back before Done) finishes it:
        // the text is recognized in the moments iOS allows, then handed over.
        notificationTokens.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .listening else { return }
                self.beginFinishingTask()
                self.finishDictation(postRoll: false)
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, typeValue == AVAudioSession.InterruptionType.began.rawValue,
                      self.phase == .listening else { return }
                // A call took the microphone: keep what was said.
                self.finishDictation(postRoll: false)
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fail(.audioEngineFailed) }
        })
    }

    private func beginFinishingTask() {
        guard finishingTask == .invalid else { return }
        finishingTask = UIApplication.shared.beginBackgroundTask(withName: "Finish dictation") { [weak self] in
            MainActor.assumeIsolated { self?.endFinishingTask() }
        }
    }

    private func endFinishingTask() {
        guard finishingTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(finishingTask)
        finishingTask = .invalid
    }

    private func ensureMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    private func fail(_ failure: VoiceSessionFailure) {
        pipeline.cancel()
        release()
        self.failure = failure
        publishNow()
    }
}
