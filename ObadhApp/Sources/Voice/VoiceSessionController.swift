import AVFoundation
import Combine
import UIKit
import os

/// The app side of voice typing: holds the microphone for a voice session, runs
/// recognition, and publishes the transcript to the keyboard. See docs/voice-typing.md.
///
/// Lifecycle:
///
///     idle ──(start)──▶ starting ──▶ ready ◀──▶ listening ──▶ finishing ──▶ ready
///       ▲                              │
///       └──(10 min without dictating, turned off, or interrupted)──┘
///
/// A backgrounded app can keep a recording alive but cannot start one, so a session
/// starts only with the app in the foreground (the keyboard's one-time bounce) or
/// from the system's audio-recording intent (Control Center, Lock Screen, Action
/// button). Once started, every dictation from the keyboard begins instantly, in any
/// app, until the session has gone unused for `sessionIdleLimit`. While no dictation
/// runs, audio is discarded as it arrives (the ring keeps only the last second).
@MainActor
final class VoiceSessionController: ObservableObject {
    static let shared = VoiceSessionController()

    /// A session with no dictation for this long ends, releasing the microphone.
    static let sessionIdleLimit: TimeInterval = 10 * 60

    @Published private(set) var phase: VoiceSessionPhase = .idle {
        didSet {
            guard phase != oldValue else { return }
            log.notice("OBADH-VOICE phase \(oldValue.rawValue, privacy: .public) -> \(self.phase.rawValue, privacy: .public)")
            if phase == .ready { idleSince = CACurrentMediaTime() }
        }
    }
    /// Audio buffers are arriving right now (watchdog-measured, not assumed).
    @Published private(set) var isAudioFlowing = false
    /// The streaming recognizer is loaded.
    @Published private(set) var isRecognizerReady = false
    @Published private(set) var transcript = VoiceTranscript.empty
    @Published private(set) var failure: VoiceSessionFailure?
    @Published private(set) var dictationID: String?

    let levels = VoiceLevelFeed()

    private let log = Logger(subsystem: "org.unmukto.obadh", category: "voice")
    private let models: VoiceModelLibrary
    private let directory: URL?
    private let levelWriter: VoiceLevelWriter?
    private let capture: VoiceAudioCapture
    private let pipeline = VoiceRecognitionPipeline()
    private var commandObserver: VoiceDarwinObserver?
    private var heartbeatTimer: Timer?
    private var watchdogTimer: Timer?
    /// When the audio last held voice (not recognized text: a quiet or unclear word
    /// must not end a dictation).
    private var lastVoiceAt: CFTimeInterval = 0
    /// When the session last became idle (ready, not dictating).
    private var idleSince: CFTimeInterval = 0
    private var snapshotSeq: UInt64 = 0
    private var lastCommandSeq: UInt64 = 0
    private var pendingPublish: DispatchWorkItem?
    private var notificationTokens: [NSObjectProtocol] = []
    /// The one bring-up in flight. A cold bounce delivers both the URL and the
    /// keyboard's start command; without this they raced through the idle check and
    /// started capture and model loading twice.
    private var bringUp: Task<Bool, Never>?
    private var recoveryAttempted = false
    /// Buffers arrive every ~50 ms; this long without one means the engine stalled.
    private static let audioStallThreshold: CFTimeInterval = 0.8

    private init(models: VoiceModelLibrary = .shared) {
        self.models = models
        directory = VoiceSessionChannel.directory()
        levelWriter = directory.flatMap { VoiceLevelWriter(url: VoiceSessionChannel.levelsURL(in: $0)) }
        capture = VoiceAudioCapture(levelWriter: levelWriter)
        levels.attach(directory.map(VoiceSessionChannel.levelsURL(in:)))
        snapshotSeq = UInt64(Date().timeIntervalSince1970 * 1000)
        wirePipeline()
        observeCommands()
        observeAudioSession()
    }

    // MARK: Entry points

    /// The keyboard opened `obadh://voice?d=<id>`: we are in the foreground, which is
    /// one of the moments a recording may start.
    func handleVoiceURL(_ url: URL) {
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == VoiceSessionChannel.dictationQueryItem }?.value
        readCommand()
        Task { await startSession(thenDictate: id) }
    }

    /// What started a session.
    enum StartSource {
        /// The keyboard opened the app (the one-time bounce).
        case keyboard
        /// Control Center, the Lock Screen, or the Action button, via the
        /// audio-recording intent. The app is in the background: nothing may prompt.
        case systemIntent
    }

    /// Start (or keep) a session. `dictationID` begins dictating at once.
    @discardableResult
    func startSession(thenDictate dictationID: String?, source: StartSource = .keyboard) async -> Bool {
        if phase == .idle {
            let task: Task<Bool, Never>
            if let bringUp {
                task = bringUp
            } else {
                task = Task { await self.performBringUp(source: source) }
                bringUp = task
            }
            let started = await task.value
            bringUp = nil
            guard started else { return false }
        }
        if let dictationID {
            beginDictation(dictationID)
        } else {
            publishNow()
        }
        return true
    }

    private func performBringUp(source: StartSource) async -> Bool {
        failure = nil
        phase = .starting
        publishNow()
        // iOS requires the Live Activity to be up before an intent starts recording.
        VoiceLiveActivityPresenter.shared.sessionStarted()
        guard await ensureMicrophonePermission(canPrompt: source == .keyboard) else {
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
        // Audio flows into the ring before the model has loaded; the recognizer
        // catches up from there, so nothing said during the load is lost.
        isRecognizerReady = false
        pipeline.load(streaming: streaming)
        recoveryAttempted = false
        startHeartbeat()
        startWatchdog()
        phase = .ready
        return true
    }

    /// Releases the microphone, unloads the model, and forgets all audio.
    func endSession() {
        pipeline.cancel()
        pipeline.unload()
        isRecognizerReady = false
        capture.isMetering = false
        capture.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        isAudioFlowing = false
        VoiceLiveActivityPresenter.shared.sessionEnded()
        phase = .idle
        dictationID = nil
        transcript = .empty
        publishNow()
    }

    /// In-app controls on the session screen.
    func finishDictation() {
        guard let dictationID else { return }
        stop(dictationID)
    }

    // MARK: Dictation

    private func beginDictation(_ id: String) {
        guard phase == .ready || phase == .listening || phase == .finishing else { return }
        if self.dictationID == id, phase == .listening { return }
        dictationID = id
        transcript = .empty
        phase = .listening
        VoiceLiveActivityPresenter.shared.dictationChanged(isDictating: true)
        capture.isMetering = true
        pipeline.begin(dictationID: id)
        lastVoiceAt = CACurrentMediaTime()
        publishNow()
    }

    private func stop(_ id: String) {
        guard dictationID == id, phase == .listening else { return }
        phase = .finishing
        capture.isMetering = false
        pipeline.finish()
        publishNow()
    }

    private func cancel(_ id: String) {
        guard dictationID == id else { return }
        pipeline.cancel()
        capture.isMetering = false
        clearDictation()
    }

    /// The keyboard has what it needs: forget the transcript, so it does not linger
    /// in the shared container.
    private func clearDictation() {
        dictationID = nil
        transcript = .empty
        VoiceLiveActivityPresenter.shared.dictationChanged(isDictating: false)
        if phase != .idle { phase = .ready }
        publishNow()
    }

    private func wirePipeline() {
        pipeline.onTranscript = { [weak self] id, transcript in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.dictationID == id else { return }
                    self.transcript = transcript
                    self.schedulePublish()
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
                    guard let self, self.dictationID == id, self.phase == .finishing else { return }
                    self.phase = .ready
                    VoiceLiveActivityPresenter.shared.dictationChanged(isDictating: false)
                    self.publishNow()
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
        pipeline.onStreamingReady = { [weak self] ready in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.phase != .idle else { return }
                    self.isRecognizerReady = ready
                    if ready { self.publishNow() } else { self.fail(.noStreamingModel) }
                }
            }
        }
    }

    // MARK: Commands from the keyboard

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
        // A command older than a few seconds was left behind by a previous keyboard
        // process; acting on it now would start dictating out of nowhere.
        guard Date().timeIntervalSince(command.issuedAt) < 10 else {
            log.notice("OBADH-VOICE ignored stale \(command.kind.rawValue, privacy: .public)")
            return
        }
        log.notice("OBADH-VOICE command \(command.kind.rawValue, privacy: .public) in phase \(self.phase.rawValue, privacy: .public)")
        switch command.kind {
        case .start:
            if phase == .idle {
                // Not running: only the foreground (the bounce) or the recording
                // intent can start us. The keyboard falls back to opening the app
                // when this goes unanswered.
                if UIApplication.shared.applicationState == .active {
                    Task { await startSession(thenDictate: command.dictationID) }
                }
            } else {
                beginDictation(command.dictationID)
            }
        case .stop:
            stop(command.dictationID)
        case .cancel:
            cancel(command.dictationID)
        case .acknowledge:
            if dictationID == command.dictationID { clearDictation() }
        case .endSession:
            endSession()
        }
    }

    // MARK: Snapshot publishing

    /// Transcript changes arrive every audio step; ~30 updates a second is plenty,
    /// and each is a file write plus a cross-process wake-up.
    private func schedulePublish() {
        guard pendingPublish == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingPublish = nil
                self?.publishNow()
            }
        }
        pendingPublish = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
    }

    private func publishNow() {
        pendingPublish?.cancel()
        pendingPublish = nil
        guard let directory else { return }
        snapshotSeq += 1
        let snapshot = VoiceSessionSnapshot(
            seq: snapshotSeq,
            phase: phase,
            heartbeat: Date(),
            dictationID: dictationID,
            transcript: transcript,
            failure: failure,
            isAudioFlowing: isAudioFlowing,
            isRecognizerReady: isRecognizerReady
        )
        do {
            try VoiceMessageFile.write(snapshot, to: VoiceSessionChannel.snapshotURL(in: directory))
            VoiceDarwinNotifier.post(VoiceSessionChannel.snapshotDarwinName)
        } catch {
            log.error("OBADH-VOICE snapshot write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Watchdog

    /// Four times a second: audio really arriving, dictation still hearing a voice,
    /// session still in use.
    private func startWatchdog() {
        watchdogTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func tick() {
        guard phase != .idle else { return }
        let now = CACurrentMediaTime()
        if phase == .listening, let dictationID,
           now - lastVoiceAt > VoiceSessionTiming.silenceEndsDictation {
            log.notice("OBADH-VOICE silence ended the dictation")
            stop(dictationID)
        }
        if phase == .ready, now - idleSince > Self.sessionIdleLimit {
            log.notice("OBADH-VOICE session unused for \(Int(Self.sessionIdleLimit / 60), privacy: .public) min; releasing the microphone")
            endSession()
            return
        }
        checkAudioFlow(now: now)
    }

    /// A stalled engine is rebuilt once; if it stays silent the session ends and
    /// says why, rather than showing "listening" while hearing nothing.
    private func checkAudioFlow(now: CFTimeInterval) {
        let flowing = now - capture.lastBufferAt < Self.audioStallThreshold
        if flowing != isAudioFlowing {
            isAudioFlowing = flowing
            log.notice("OBADH-VOICE audio \(flowing ? "flowing" : "stalled", privacy: .public)")
            publishNow()
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
            log.error("OBADH-VOICE capture rebuild failed: \(String(describing: error), privacy: .public)")
            fail(.audioEngineFailed)
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let timer = Timer(timeInterval: VoiceSessionTiming.heartbeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    // MARK: Audio session

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

    private func observeAudioSession() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, typeValue == AVAudioSession.InterruptionType.began.rawValue else { return }
                // A call (or another recorder) took the microphone. The session cannot
                // be restarted from the background, so end it cleanly and say why.
                self.fail(.interrupted)
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fail(.audioEngineFailed) }
        })
    }

    private func ensureMicrophonePermission(canPrompt: Bool) async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return canPrompt ? await AVAudioApplication.requestRecordPermission() : false
        }
    }

    private func fail(_ failure: VoiceSessionFailure) {
        let keptDictation = dictationID
        endSession()
        self.failure = failure
        dictationID = keptDictation
        publishNow()
    }
}
