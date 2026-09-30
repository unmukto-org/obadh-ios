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
    var hasFinalText: Bool { transcript.isFinal && dictationID != nil && failure == nil }

    let levels = VoiceLevelFeed()

    private let log = Logger(subsystem: "org.unmukto.obadh", category: "voice")
    private let modelConfiguration: () -> VoiceRecognitionPipeline.StreamingConfiguration?
    private let permission: () async -> Bool
    private let configureSession: () throws -> Void
    private let deactivateSession: () -> Void
    private let makePipeline: () -> any VoiceRecognizing
    private let finishTimeout: TimeInterval
    private let directory: URL?
    private let levelWriter: VoiceLevelWriter?
    private let capture: any VoiceAudioCapturing
    private var pipeline: (any VoiceRecognizing)?
    private var commandObserver: VoiceDarwinObserver?
    private var watchdogTimer: Timer?
    /// When the audio last held voice (a quiet or unclear word must not end a
    /// dictation, so this is voice activity, not recognized text).
    private var lastVoiceAt: CFTimeInterval = 0
    private var snapshotSeq: UInt64 = 0
    private var lastCommandSeq: UInt64 = 0
    private var notificationTokens: [NSObjectProtocol] = []
    /// Invalidates every callback and suspended permission request from an old trip.
    private var generation: UInt64 = 0
    private var finishDeadline: Task<Void, Never>?
    private var postRollTask: Task<Void, Never>?
    private var modelDeadline: Task<Void, Never>?
    private var recognizerReady = false
    private var recoveryAttempted = false
    /// Keeps the app running long enough to finish a dictation the user left mid-way.
    private var finishingTask: UIBackgroundTaskIdentifier = .invalid
    /// Buffers arrive every ~50 ms; this long without one means the engine stalled.
    private static let audioStallThreshold: CFTimeInterval = 0.8
    /// How long a freshly started engine may take to deliver its first buffer.
    private static let audioStartThreshold: CFTimeInterval = 3

    init(
        directory: URL? = VoiceSessionChannel.directory(),
        capture: (any VoiceAudioCapturing)? = nil,
        makePipeline: @escaping () -> any VoiceRecognizing = { VoiceRecognitionPipeline() },
        modelConfiguration: @escaping () -> VoiceRecognitionPipeline.StreamingConfiguration? = {
            VoiceModelLibrary.shared.activeStreamingConfiguration()
        },
        permission: @escaping () async -> Bool = { await VoiceSessionController.ensureMicrophonePermission() },
        configureSession: @escaping () throws -> Void = { try VoiceSessionController.configureAudioSession() },
        deactivateSession: @escaping () -> Void = {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        },
        finishTimeout: TimeInterval = VoiceSessionTiming.finishTimeout,
        observeSystem: Bool = true
    ) {
        self.directory = directory
        self.modelConfiguration = modelConfiguration
        self.permission = permission
        self.configureSession = configureSession
        self.deactivateSession = deactivateSession
        self.makePipeline = makePipeline
        self.finishTimeout = finishTimeout
        levelWriter = directory.flatMap { VoiceLevelWriter(url: VoiceSessionChannel.levelsURL(in: $0)) }
        self.capture = capture ?? VoiceAudioCapture(levelWriter: levelWriter)
        levels.attach(directory.map(VoiceSessionChannel.levelsURL(in:)))
        snapshotSeq = UInt64(Date().timeIntervalSince1970 * 1000)
        if let directory,
           let saved = VoiceMessageFile.read(VoiceSessionSnapshot.self, from: VoiceSessionChannel.snapshotURL(in: directory)),
           saved.transcript.isFinal, saved.dictationID != nil {
            transcript = saved.transcript
            dictationID = saved.dictationID
            failure = saved.failure
            snapshotSeq = max(snapshotSeq, saved.seq)
        }
        if observeSystem {
            observeCommands()
            observeLifecycle()
        }
    }

    // MARK: Entry points

    /// The keyboard opened `obadh://voice?d=<id>`: start dictating at once.
    func handleVoiceURL(_ url: URL) {
        guard let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == VoiceSessionChannel.dictationQueryItem })?.value else { return }
        Task { await startDictation(id) }
    }

    func startDictation(_ id: String) async {
        guard !id.isEmpty, dictationID != id else { return }
        release()
        let attempt = generation
        dictationID = id
        transcript = .empty
        failure = nil
        phase = .starting
        guard publishNow() else { fail(.deliveryUnavailable); return }
        let allowed = await permission()
        guard generation == attempt, dictationID == id else { return }
        guard !Task.isCancelled else { cancelDictation(); return }
        guard allowed else {
            fail(.microphonePermissionDenied)
            return
        }
        guard let streaming = modelConfiguration() else {
            fail(.noStreamingModel)
            return
        }
        let pipeline = makePipeline()
        self.pipeline = pipeline
        wirePipeline(pipeline, attempt: attempt)
        // Arm before capture/model load so cold-start audio belongs to this trip.
        pipeline.begin(dictationID: id)
        do {
            try configureSession()
            try capture.start()
        } catch {
            log.error("OBADH-VOICE audio start failed: \(String(describing: error), privacy: .public)")
            fail(.audioEngineFailed)
            return
        }
        // Audio flows into the ring before the model has loaded; recognition catches
        // up from there, so nothing said during the load is lost.
        pipeline.load(streaming: streaming)
        phase = .listening
        capture.isMetering = true
        lastVoiceAt = CACurrentMediaTime()
        recoveryAttempted = false
        startWatchdog()
        modelDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.generation == attempt,
                  !self.recognizerReady else { return }
            self.fail(.finishTimedOut)
        }
        publishNow()
    }

    /// Done: take the last moment of audio, recognize it, then release the mic.
    /// `postRoll` is off when the microphone is about to stop anyway (leaving the
    /// screen, a call): the dictation then ends at what was already heard.
    func finishDictation(postRoll: Bool = true) {
        guard phase == .listening || phase == .finishing else { return }
        let wasFinishing = phase == .finishing
        phase = .finishing
        capture.isMetering = false
        pipeline?.finish(postRoll: postRoll)
        if !postRoll {
            postRollTask?.cancel()
            capture.stop()
            isAudioFlowing = false
        }
        guard !wasFinishing else { return }
        let attempt = generation
        if postRoll {
            postRollTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self, self.generation == attempt else { return }
                self.capture.stop()
                self.isAudioFlowing = false
                self.pipeline?.finish(postRoll: false)
            }
        }
        finishDeadline = Task { [weak self] in
            guard let timeout = self?.finishTimeout else { return }
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, self.generation == attempt,
                  self.phase == .finishing else { return }
            self.fail(.finishTimedOut)
        }
    }

    /// Cancel: nothing is kept or inserted.
    func cancelDictation() {
        let cancelledID = dictationID
        release()
        dictationID = nil
        transcript = .empty
        failure = nil
        publishNow(dictationID: cancelledID)
    }

    /// Microphone off, model unloaded, all audio forgotten. The final text (if any)
    /// stays until the keyboard has inserted it.
    private func release() {
        generation &+= 1
        finishDeadline?.cancel()
        finishDeadline = nil
        postRollTask?.cancel()
        postRollTask = nil
        modelDeadline?.cancel()
        modelDeadline = nil
        pipeline?.cancel()
        pipeline?.unload()
        pipeline = nil
        recognizerReady = false
        capture.isMetering = false
        capture.stop()
        capture.onSamples = nil
        capture.onFailure = nil
        deactivateSession()
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        isAudioFlowing = false
        phase = .idle
        endFinishingTask()
    }

    // MARK: Pipeline

    private func wirePipeline(_ pipeline: any VoiceRecognizing, attempt: UInt64) {
        pipeline.onTranscript = { [weak self] id, transcript in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == attempt, self.dictationID == id else { return }
                    // Shown on the voice screen directly; nothing crosses to the
                    // keyboard until the text is final.
                    self.transcript = transcript
                }
            }
        }
        pipeline.onVoiceActivity = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == attempt else { return }
                    self.lastVoiceAt = CACurrentMediaTime()
                }
            }
        }
        pipeline.onFinished = { [weak self] id in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == attempt, self.dictationID == id else { return }
                    self.release()
                    self.log.notice("OBADH-VOICE dictation final: \(self.transcript.text.count, privacy: .public) chars; microphone released")
                    self.publishNow()
                }
            }
        }
        pipeline.onStreamingReady = { [weak self] ready in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == attempt, self.phase != .idle else { return }
                    self.recognizerReady = ready
                    self.lastVoiceAt = CACurrentMediaTime()
                    if ready { self.modelDeadline?.cancel() }
                    else { self.fail(.noStreamingModel) }
                }
            }
        }
        capture.onSamples = { [pipeline] samples in
            pipeline.append(samples)
        }
        capture.onFailure = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == attempt else { return }
                    self.fail(.audioEngineFailed)
                }
            }
        }
        pipeline.onFailure = { [weak self] id, failure in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == attempt, self.dictationID == id else { return }
                    self.fail(failure)
                }
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
        log.notice("OBADH-VOICE command \(command.kind.rawValue, privacy: .public)")
        switch command.kind {
        case .acknowledge:
            // Inserted: the text is forgotten here.
            guard dictationID == command.dictationID, phase == .idle, transcript.isFinal else { return }
            dictationID = nil
            transcript = .empty
            publishNow()
        case .cancel:
            guard Date().timeIntervalSince(command.issuedAt) < 60 else { return }
            if dictationID == command.dictationID { cancelDictation() }
        case .start, .stop, .endSession:
            break
        }
    }

    /// Re-read on foreground entry, including notifications missed in suspension.
    func refreshAcknowledgement() { readCommand() }

    /// The snapshot is written only when something the keyboard needs changes: a
    /// dictation starts (so a returning keyboard knows to wait), or its final text is
    /// ready. Never per partial.
    @discardableResult
    private func publishNow(dictationID overrideID: String? = nil) -> Bool {
        guard let directory else { failure = .deliveryUnavailable; return false }
        snapshotSeq += 1
        let snapshot = VoiceSessionSnapshot(
            seq: snapshotSeq,
            phase: phase,
            heartbeat: Date(),
            dictationID: overrideID ?? dictationID,
            transcript: transcript.isFinal ? transcript : .empty,
            failure: failure,
            isAudioFlowing: isAudioFlowing,
            isRecognizerReady: nil
        )
        do {
            try VoiceMessageFile.write(snapshot, to: VoiceSessionChannel.snapshotURL(in: directory))
            VoiceDarwinNotifier.post(VoiceSessionChannel.snapshotDarwinName)
            return true
        } catch {
            log.error("OBADH-VOICE snapshot write failed: \(error.localizedDescription, privacy: .public)")
            failure = .deliveryUnavailable
            return false
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
        if recognizerReady, now - lastVoiceAt > VoiceSessionTiming.silenceEndsDictation {
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

    private static func configureAudioSession() throws {
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
                self?.applicationWillResignActive()
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, typeValue == AVAudioSession.InterruptionType.began.rawValue,
                      self.phase == .listening || self.phase == .finishing else { return }
                // A call took the microphone: keep what was said.
                self.finishDictation(postRoll: false)
            }
        })
        notificationTokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // The permission alert itself only resigns active; it is not a
                // departure. A real departure must invalidate a suspended start.
                if self?.phase == .starting { self?.cancelDictation() }
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase != .idle else { return }
                self.fail(.audioEngineFailed)
            }
        })
    }

    private func beginFinishingTask() {
        guard finishingTask == .invalid else { return }
        finishingTask = UIApplication.shared.beginBackgroundTask(withName: "Finish dictation") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.phase == .finishing { self.fail(.finishTimedOut) }
                self.endFinishingTask()
            }
        }
    }

    private func endFinishingTask() {
        guard finishingTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(finishingTask)
        finishingTask = .invalid
    }

    private static func ensureMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    private func fail(_ failure: VoiceSessionFailure) {
        release()
        // Keep the last recognized words for explicit copy/recovery. Never
        // silently auto-insert an incomplete result as if it were successful.
        transcript.stableLength = transcript.text.count
        transcript.isFinal = true
        self.failure = failure
        publishNow()
    }

    func applicationWillResignActive() {
        guard phase == .listening || phase == .finishing else { return }
        beginFinishingTask()
        finishDictation(postRoll: false)
    }
}
