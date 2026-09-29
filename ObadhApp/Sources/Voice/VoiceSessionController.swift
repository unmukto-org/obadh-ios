import AVFoundation
import Combine
import UIKit
import os

/// The app side of voice typing: holds the microphone for a warm session, runs the
/// recognizers, and publishes the transcript to the keyboard. See docs/voice-typing.md.
///
/// Lifecycle:
///
///     idle ──(foreground start)──▶ starting ──▶ ready ◀──▶ listening ──▶ finishing ──▶ ready
///       ▲                                         │
///       └────────────(warm window expires)────────┘
///
/// A backgrounded app can keep a recording alive but cannot start one, so the only
/// way into `starting` is with the app in the foreground (the keyboard's bounce).
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
    /// The streaming recognizer is loaded.
    @Published private(set) var isRecognizerReady = false
    @Published private(set) var segments: [VoiceSegment] = []
    @Published private(set) var failure: VoiceSessionFailure?
    @Published private(set) var expiresAt: Date?
    @Published private(set) var dictationID: String?

    /// The live transcript, for the in-app session screen.
    var transcript: String {
        segments.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }

    let levels: VoiceLevelSource

    private let log = Logger(subsystem: "org.unmukto.obadh", category: "voice")
    private let preferences = VoicePreferences()
    private let models: VoiceModelLibrary
    private let directory: URL?
    private let levelWriter: VoiceLevelWriter?
    private let capture: VoiceAudioCapture
    private let pipeline = VoiceRecognitionPipeline()
    private var commandObserver: VoiceDarwinObserver?
    private var heartbeatTimer: Timer?
    private var expiryTimer: Timer?
    private var snapshotSeq: UInt64 = 0
    private var lastCommandSeq: UInt64 = 0
    private var pendingPublish: DispatchWorkItem?
    private var hearsSpeech = false
    private var notificationTokens: [NSObjectProtocol] = []
    /// The one bring-up in flight. A cold bounce delivers both the URL and the
    /// keyboard's start command; without this they raced through the idle check and
    /// started capture and model loading twice.
    private var bringUp: Task<Bool, Never>?
    private var watchdogTimer: Timer?
    private var recoveryAttempted = false
    /// Buffers arrive every ~50 ms; this long without one means the engine stalled.
    private static let audioStallThreshold: CFTimeInterval = 0.8

    private init(models: VoiceModelLibrary = .shared) {
        self.models = models
        directory = VoiceSessionChannel.directory()
        levelWriter = directory.flatMap { VoiceLevelWriter(url: VoiceSessionChannel.levelsURL(in: $0)) }
        capture = VoiceAudioCapture(levelWriter: levelWriter)
        levels = VoiceAppLevelSource(url: directory.map(VoiceSessionChannel.levelsURL(in:)))
        snapshotSeq = UInt64(Date().timeIntervalSince1970 * 1000)
        wirePipeline()
        observeCommands()
        observeAudioSession()
    }

    // MARK: Entry points

    /// The keyboard opened `obadh://voice?d=<id>`: we are in the foreground, which is
    /// the one moment a recording may start.
    func handleVoiceURL(_ url: URL) {
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == VoiceSessionChannel.dictationQueryItem }?.value
        readCommand()
        Task { await startSession(thenDictate: id) }
    }

    /// Start (or keep) a warm session. `dictationID` begins dictating at once.
    func startSession(thenDictate dictationID: String?) async {
        if phase == .idle {
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
        }
        if let dictationID {
            beginDictation(dictationID)
        } else {
            publishNow()
        }
    }

    private func performBringUp() async -> Bool {
        failure = nil
        phase = .starting
        publishNow()
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
        // Audio is flowing (and buffered) before the model finishes loading, so
        // nothing said during the load is lost.
        isRecognizerReady = false
        pipeline.load(streaming: streaming, refiner: models.activeRefinerConfiguration())
        recoveryAttempted = false
        startHeartbeat()
        startWatchdog()
        phase = .ready
        refreshExpiry()
        return true
    }

    func endSession() {
        pipeline.cancel()
        capture.isMetering = false
        capture.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        isAudioFlowing = false
        expiryTimer?.invalidate()
        expiryTimer = nil
        phase = .idle
        dictationID = nil
        segments = []
        expiresAt = nil
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
        segments = []
        hearsSpeech = false
        phase = .listening
        capture.isMetering = true
        pipeline.begin(dictationID: id)
        expiryTimer?.invalidate()
        expiresAt = nil
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
        segments = []
        if phase != .idle { phase = .ready }
        refreshExpiry()
        publishNow()
    }

    private func wirePipeline() {
        pipeline.onSegments = { [weak self] id, segments, hears in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.dictationID == id else { return }
                    self.segments = segments
                    self.hearsSpeech = hears
                    self.schedulePublish()
                }
            }
        }
        pipeline.onFinished = { [weak self] id in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.dictationID == id, self.phase == .finishing else { return }
                    self.phase = .ready
                    self.refreshExpiry()
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
                // Not running: only the foreground bounce can start us. The keyboard
                // falls back to opening the app when this goes unanswered.
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

    /// Partials arrive every audio buffer; the keyboard does not need more than
    /// ~25 updates a second, and each is a file write plus a cross-process wake-up.
    private func schedulePublish() {
        guard pendingPublish == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingPublish = nil
                self?.publishNow()
            }
        }
        pendingPublish = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
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
            segments: segments,
            expiresAt: expiresAt,
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

    /// Checks four times a second that audio is really arriving. A stalled engine is
    /// rebuilt once; if it stays silent the session ends and says why, rather than
    /// showing "listening" while hearing nothing.
    private func startWatchdog() {
        watchdogTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAudioHealth() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func checkAudioHealth() {
        guard phase != .idle else { return }
        let flowing = CACurrentMediaTime() - capture.lastBufferAt < Self.audioStallThreshold
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

    // MARK: Warm window

    @discardableResult
    private func refreshExpiry() -> Date {
        let expiry = Date().addingTimeInterval(preferences.warmWindow)
        expiresAt = expiry
        expiryTimer?.invalidate()
        let timer = Timer(fire: expiry, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .ready else { return }
                self.log.notice("OBADH-VOICE warm window expired; releasing the microphone")
                self.endSession()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
        return expiry
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

    private func ensureMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
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

/// The app reads its own level page, so the session screen shows exactly what the
/// keyboard shows.
@MainActor
private final class VoiceAppLevelSource: VoiceLevelSource {
    private let url: URL?
    private var reader: VoiceLevelReader?

    init(url: URL?) {
        self.url = url
    }

    func currentFrame() -> VoiceLevelFrame {
        if reader == nil, let url { reader = VoiceLevelReader(url: url) }
        return reader?.read() ?? .silent
    }
}
