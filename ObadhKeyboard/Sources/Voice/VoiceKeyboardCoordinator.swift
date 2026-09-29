import UIKit
import os

/// What the coordinator needs from the keyboard controller. Kept narrow so the voice
/// path cannot reach into typing state it has no business touching.
@MainActor
protocol VoiceKeyboardHost: AnyObject {
    var voiceHasFullAccess: Bool { get }
    var voiceDocument: TextDocumentEditing { get }
    /// Commit whatever word is being typed, so dictation starts after it.
    func voiceWillBeginDictation()
    /// Show voice typing's state in the suggestion strip; nil restores suggestions.
    func voiceShowIndicator(_ phase: VoicePanelPhase?)
    func voiceMicStateDidChange(_ state: SuggestionMicControl.Mode)
    /// Run proxy edits with the controller's own text-change callbacks suppressed.
    func voicePerformTextUpdate(_ update: () -> Void)
    func voiceOpenContainingApp(_ url: URL, completion: @escaping (Bool) -> Void)
}

/// Keyboard side of voice typing. The keyboard cannot record, so this is a remote
/// control plus a text writer: it sends start / stop to the app, and applies the
/// transcript the app publishes to the document. See docs/voice-typing.md.
@MainActor
final class VoiceKeyboardCoordinator {
    private let log = Logger(subsystem: "org.unmukto.obadh.keyboard", category: "voice")
    weak var host: VoiceKeyboardHost?
    /// The phase shown in the strip while voice typing is active.
    private(set) var phase: VoicePanelPhase = .connecting
    let levels = VoiceLevelFeed()

    private var reconciler = VoiceDraftReconciler()
    private var lastSnapshot = VoiceSessionSnapshot.empty
    private var lastCommandSeq: UInt64 = 0
    private var snapshotObserver: VoiceDarwinObserver?
    private var warmthTimer: Timer?
    private var acknowledgementDeadline: DispatchWorkItem?
    /// Draft writes are paced: each is several round trips to the host, and a host
    /// fed faster than it echoes back reads stale.
    private var pendingApply: DispatchWorkItem?
    private var lastApplyAt: CFTimeInterval = 0
    private static let applyInterval: CFTimeInterval = 0.08
    /// Since when the document has not shown our draft. A brief mismatch is a host
    /// catching up; only a persistent one means the text moved.
    private var staleSince: CFTimeInterval?
    private static let staleRetry: CFTimeInterval = 0.15
    private static let staleGiveUp: CFTimeInterval = 0.6
    private var finishDeadline: DispatchWorkItem?
    /// True from opening the app until the keyboard reappears, so the disappearance
    /// the bounce causes is not mistaken for the user leaving mid-dictation.
    private var isHandingOff = false
    private(set) var isPanelVisible = false

    private let persistence = UserDefaults.standard
    private static let persistedReconcilerKey = "voice.keyboard.reconciler"

    init() {}

    /// A key was typed while dictating: finish first, like system dictation, so
    /// typed and dictated text never compete for the cursor. The draft stays as
    /// written; a late refinement lands only if the text is still untouched.
    func finishBeforeTyping() {
        guard isPanelVisible, reconciler.isActive else { return }
        finish(returnToKeys: true)
    }

    var isDictating: Bool { isPanelVisible && reconciler.isActive }

    private var directory: URL? { VoiceSessionChannel.directory() }

    // MARK: Lifecycle, driven by the controller

    func hostWillAppear() {
        isHandingOff = false
        if snapshotObserver == nil {
            snapshotObserver = VoiceDarwinObserver(name: VoiceSessionChannel.snapshotDarwinName) { [weak self] in
                self?.snapshotDidChange()
            }
        }
        touchPresence()
        restorePersistedDictation()
        snapshotDidChange()
        startWarmthTimer()
    }

    func hostDidDisappear() {
        warmthTimer?.invalidate()
        warmthTimer = nil
        levels.detach()
        // Opening the app for the bounce is the one disappearance that is not goodbye.
        guard !isHandingOff else { return }
        // The keyboard is closing (dismissed, another keyboard, another app): the
        // microphone must not outlive it. Any dictation in flight is dropped rather
        // than inserted into whatever field happens to be focused later.
        if let dictationID = reconciler.dictationID {
            send(.cancel, dictationID: dictationID)
            endDictation()
        }
        if lastSnapshot.phase != .idle {
            log.notice("OBADH-VOICE keyboard closing; releasing the microphone")
            send(.endSession, dictationID: "")
        }
    }

    // MARK: Mic

    func micTapped() {
        if isPanelVisible, reconciler.isActive {
            finish(returnToKeys: false)
            return
        }
        guard let host else { return }
        guard host.voiceHasFullAccess, directory != nil else {
            showProblem("ভয়েস টাইপিংয়ের জন্য সেটিংসে Allow Full Access চালু করুন")
            return
        }
        host.voiceWillBeginDictation()
        let dictationID = String(UUID().uuidString.prefix(8)).lowercased()
        reconciler.begin(dictationID: dictationID, contextBefore: host.voiceDocument.contextBeforeInput)
        persistReconciler()
        send(.start, dictationID: dictationID)
        setPhase(.connecting)
        setPanelVisible(true)

        let snapshot = readSnapshot() ?? .empty
        log.notice("OBADH-VOICE tap: \(snapshot.isWarm() ? "warm start" : "bounce", privacy: .public) (app phase \(snapshot.phase.rawValue, privacy: .public))")
        if snapshot.isWarm() {
            // The app is holding the mic open; it should pick this up within one audio
            // buffer. If it doesn't (suspended between heartbeats), fall back to the bounce.
            let deadline = DispatchWorkItem { [weak self] in
                self?.log.notice("OBADH-VOICE warm start unanswered; opening the app")
                self?.openApp(for: dictationID)
            }
            acknowledgementDeadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + VoiceSessionTiming.warmStartAcknowledgementTimeout, execute: deadline)
        } else {
            openApp(for: dictationID)
        }
    }

    private func openApp(for dictationID: String) {
        guard reconciler.dictationID == dictationID, let host else { return }
        isHandingOff = true
        host.voiceOpenContainingApp(VoiceSessionChannel.voiceURL(dictationID: dictationID)) { [weak self] opened in
            guard let self, !opened else { return }
            self.isHandingOff = false
            self.showProblem("অবাধ অ্যাপ খোলা যায়নি")
            self.endDictation()
        }
    }

    // MARK: Finishing

    private func finish(returnToKeys: Bool) {
        guard let dictationID = reconciler.dictationID else {
            setPanelVisible(false)
            return
        }
        send(.stop, dictationID: dictationID)
        if returnToKeys {
            setPanelVisible(false)
        } else {
            setPhase(.finishing)
        }
        // Refinement usually lands well inside this; if it doesn't, the streaming
        // text stays as written and the keyboard moves on.
        finishDeadline?.cancel()
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.reconciler.dictationID == dictationID else { return }
            self.send(.acknowledge, dictationID: dictationID)
            self.endDictation()
        }
        finishDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + VoiceSessionTiming.finishTimeout, execute: deadline)
    }

    private func endDictation() {
        if reconciler.isActive { log.notice("OBADH-VOICE dictation ended") }
        acknowledgementDeadline?.cancel()
        pendingApply?.cancel()
        pendingApply = nil
        staleSince = nil
        finishDeadline?.cancel()
        reconciler.end()
        persistReconciler()
        setPanelVisible(false)
        publishMicState()
    }

    // MARK: Snapshots

    private func snapshotDidChange() {
        guard let snapshot = readSnapshot(), snapshot.seq >= lastSnapshot.seq else {
            publishMicState()
            return
        }
        lastSnapshot = snapshot
        defer { publishMicState() }
        guard let dictationID = reconciler.dictationID, snapshot.dictationID == dictationID else {
            // The app moved on without us (restarted, or a newer dictation): a stale
            // local dictation can never complete, so let it go.
            if reconciler.isActive, snapshot.isWarm(), snapshot.phase == .ready, snapshot.dictationID != nil {
                endDictation()
            }
            return
        }
        if acknowledgementDeadline?.isCancelled == false {
            acknowledgementDeadline?.cancel()
            log.notice("OBADH-VOICE app acknowledged in phase \(snapshot.phase.rawValue, privacy: .public)")
        }
        updatePanelPhase(from: snapshot)
        scheduleApply(after: 0)
    }

    private func scheduleApply(after delay: CFTimeInterval) {
        pendingApply?.cancel()
        let wait = max(delay, Self.applyInterval - (CACurrentMediaTime() - lastApplyAt))
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingApply = nil
                self.lastApplyAt = CACurrentMediaTime()
                self.apply(self.lastSnapshot)
            }
        }
        pendingApply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, wait), execute: work)
    }

    private func updatePanelPhase(from snapshot: VoiceSessionSnapshot) {
        guard isPanelVisible else { return }
        if let failure = snapshot.failure {
            showProblem(Self.message(for: failure))
            return
        }
        switch snapshot.phase {
        case .idle, .starting:
            setPhase(.connecting)
        case .ready:
            if phase != .finishing { setPhase(.ready) }
        case .listening:
            // Only claim to listen while the app reports audio actually arriving; a
            // stalled engine shows as connecting while the app's watchdog recovers.
            if snapshot.isAudioFlowing == false {
                setPhase(.connecting)
            } else {
                let heard = snapshot.segments.contains { !$0.text.isEmpty }
                setPhase(heard ? .listening : .ready)
            }
        case .finishing:
            setPhase(.finishing)
        }
    }

    private func apply(_ snapshot: VoiceSessionSnapshot) {
        guard let host, let step = reconciler.step(for: snapshot) else { return }
        var outcome = VoiceDraftWriter.Outcome.applied
        host.voicePerformTextUpdate {
            outcome = VoiceDraftWriter().apply(step, in: host.voiceDocument)
        }
        switch outcome {
        case .applied:
            staleSince = nil
            reconciler.didApply(step, snapshot: snapshot)
        case .stale:
            let now = CACurrentMediaTime()
            let since = staleSince ?? now
            staleSince = since
            guard now - since >= Self.staleGiveUp else {
                // Most likely the host has not caught up yet: try again shortly.
                scheduleApply(after: Self.staleRetry)
                return
            }
            staleSince = nil
            let window = host.voiceDocument.contextBeforeInput?.count ?? -1
            log.notice("OBADH-VOICE draft no longer at the cursor (host window \(window, privacy: .public), draft \(step.currentText.count, privacy: .public)); continuing at the cursor")
            reconciler.abandonTracked(snapshot: snapshot, contextBefore: host.voiceDocument.contextBeforeInput)
        }
        if step.completesDictation, let dictationID = reconciler.dictationID {
            send(.acknowledge, dictationID: dictationID)
            endDictation()
        } else {
            persistReconciler()
        }
    }

    // MARK: Mic state

    private func startWarmthTimer() {
        warmthTimer?.invalidate()
        // Once a second while visible: tell the app the keyboard is still here (the
        // microphone is held only while it is), and re-check warmth, which decays
        // silently if the app is suspended. Stops on disappear.
        let timer = Timer(timeInterval: VoiceSessionTiming.presenceInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.touchPresence()
                self?.snapshotDidChange()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        warmthTimer = timer
    }

    private func publishMicState() {
        let state: SuggestionMicControl.Mode
        if isPanelVisible, reconciler.isActive {
            state = .listening
        } else if lastSnapshot.isWarm() {
            state = .warm
        } else {
            state = .idle
        }
        host?.voiceMicStateDidChange(state)
    }

    private func setPanelVisible(_ visible: Bool) {
        guard visible != isPanelVisible else { return }
        isPanelVisible = visible
        if visible {
            levels.attach(directory.map(VoiceSessionChannel.levelsURL(in:)))
        } else {
            levels.detach()
        }
        host?.voiceShowIndicator(visible ? phase : nil)
        publishMicState()
    }

    private func setPhase(_ newPhase: VoicePanelPhase) {
        phase = newPhase
        if isPanelVisible { host?.voiceShowIndicator(newPhase) }
    }

    private func showProblem(_ message: String) {
        setPhase(.problem(message))
        setPanelVisible(true)
        let dictationID = reconciler.dictationID
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.reconciler.dictationID == dictationID,
                  case .problem = self.phase else { return }
            self.endDictation()
        }
    }

    private static func message(for failure: VoiceSessionFailure) -> String {
        switch failure {
        case .microphonePermissionDenied: "অবাধ অ্যাপে মাইক্রোফোনের অনুমতি দিন"
        case .noStreamingModel: "অবাধ অ্যাপে ভয়েস মডেল ডাউনলোড করুন"
        case .audioEngineFailed: "মাইক্রোফোন চালু করা যায়নি"
        case .interrupted: "অন্য একটি অ্যাপ মাইক্রোফোন ব্যবহার করছে"
        }
    }

    // MARK: IPC

    /// A zero-byte file whose modification date says "the keyboard is on screen".
    private func touchPresence() {
        guard let directory else { return }
        let url = VoiceSessionChannel.presenceURL(in: directory)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        } else {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }
    }

    private func readSnapshot() -> VoiceSessionSnapshot? {
        guard let directory else { return nil }
        return VoiceMessageFile.read(VoiceSessionSnapshot.self, from: VoiceSessionChannel.snapshotURL(in: directory))
    }

    private func send(_ kind: VoiceCommandKind, dictationID: String) {
        guard let directory else { return }
        // Wall-clock milliseconds, bumped past the last value: monotonic even across
        // keyboard process restarts, which reset any in-memory counter.
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        lastCommandSeq = max(lastCommandSeq + 1, now)
        let command = VoiceCommand(seq: lastCommandSeq, kind: kind, dictationID: dictationID, issuedAt: Date())
        do {
            try VoiceMessageFile.write(command, to: VoiceSessionChannel.commandURL(in: directory))
            VoiceDarwinNotifier.post(VoiceSessionChannel.commandDarwinName)
        } catch {
            log.error("OBADH-VOICE command write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    #if DEBUG
    /// `voice:demo|listening|ready|finishing|connecting|problem|off` shows the panel in a
    /// given phase with synthetic levels, for reviewing the visual on the simulator.
    func debugShowPanel(_ argument: String?) {
        let phase: VoicePanelPhase?
        switch argument ?? "demo" {
        case "demo", "listening": phase = .listening
        case "ready": phase = .ready
        case "finishing": phase = .finishing
        case "connecting": phase = .connecting
        case "problem": phase = .problem("অবাধ অ্যাপে ভয়েস মডেল ডাউনলোড করুন")
        default: phase = nil
        }
        levels.isSynthetic = phase != nil
        guard let phase else {
            setPanelVisible(false)
            return
        }
        setPhase(phase)
        setPanelVisible(true)
    }
    #endif

    // MARK: Surviving the bounce

    /// iOS often terminates the keyboard process while the user is in the app. The
    /// dictation's bookkeeping is persisted so the returning keyboard (a new process)
    /// knows which dictation it owns and what it has already written.
    private func persistReconciler() {
        if reconciler.isActive, let data = try? JSONEncoder().encode(reconciler) {
            persistence.set(data, forKey: Self.persistedReconcilerKey)
        } else {
            persistence.removeObject(forKey: Self.persistedReconcilerKey)
        }
    }

    private func restorePersistedDictation() {
        guard !reconciler.isActive,
              let data = persistence.data(forKey: Self.persistedReconcilerKey),
              let restored = try? JSONDecoder().decode(VoiceDraftReconciler.self, from: data) else { return }
        // Only while the app still holds that dictation (it clears the id once the
        // dictation is acknowledged, cancelled, or the session ends).
        guard let snapshot = readSnapshot(), snapshot.dictationID == restored.dictationID else {
            persistence.removeObject(forKey: Self.persistedReconcilerKey)
            return
        }
        reconciler = restored
        let live = snapshot.phase == .listening || snapshot.phase == .ready || snapshot.phase == .starting
        setPhase(snapshot.phase == .finishing ? .finishing : (live ? .ready : .finishing))
        setPanelVisible(true)
    }
}
