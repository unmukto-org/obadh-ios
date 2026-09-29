import UIKit
import os

/// What the coordinator needs from the keyboard controller. Kept narrow so the voice
/// path cannot reach into typing state it has no business touching.
@MainActor
protocol VoiceKeyboardHost: AnyObject {
    var voiceHasFullAccess: Bool { get }
    var voiceDocument: TextDocumentEditing { get }
    /// Commit whatever word is being typed, so dictated text lands after it.
    func voiceWillBeginDictation()
    /// A short message in the suggestion strip, for something the user must act on;
    /// nil restores the suggestions.
    func voiceShowIndicator(_ phase: VoicePanelPhase?)
    func voiceMicStateDidChange(_ state: SuggestionMicControl.Mode)
    /// Run proxy edits with the controller's own text-change callbacks suppressed.
    func voicePerformTextUpdate(_ update: () -> Void)
    func voiceOpenContainingApp(_ url: URL, completion: @escaping (Bool) -> Void)
}

/// Keyboard side of voice typing, one dictation at a time.
///
/// A keyboard cannot use the microphone, so the mic opens Obadh's voice screen,
/// which listens, shows the words, and releases the microphone once the text is
/// final. When the user comes back, this inserts that final text in one append and
/// acknowledges it. Nothing is written into the field while the user is speaking,
/// so there is nothing to rewrite, and nothing to jitter. See docs/voice-typing.md.
@MainActor
final class VoiceKeyboardCoordinator {
    private let log = Logger(subsystem: "org.unmukto.obadh.keyboard", category: "voice")
    weak var host: VoiceKeyboardHost?

    /// The dictation this keyboard is waiting for, with where its text will go.
    private var reconciler = VoiceDraftReconciler()
    private var snapshotObserver: VoiceDarwinObserver?
    private var lastCommandSeq: UInt64 = 0
    private var waitTimeout: DispatchWorkItem?
    private var problemDismissal: DispatchWorkItem?

    private let persistence = UserDefaults.standard
    private static let persistedKey = "voice.keyboard.pendingDictation"
    /// How long a returning keyboard waits for text before giving up quietly.
    private static let returnWait: TimeInterval = 6

    private var directory: URL? { VoiceSessionChannel.directory() }

    // MARK: Lifecycle, driven by the controller

    func hostWillAppear() {
        if snapshotObserver == nil {
            snapshotObserver = VoiceDarwinObserver(name: VoiceSessionChannel.snapshotDarwinName) { [weak self] in
                self?.deliverIfReady()
            }
        }
        restorePending()
        guard reconciler.isActive else { return }
        // Back from the voice screen: the text is usually final already; if the user
        // left mid-dictation it arrives within a moment.
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.reconciler.isActive else { return }
            self.log.notice("OBADH-VOICE no text arrived; giving up")
            self.clearPending()
        }
        waitTimeout?.cancel()
        waitTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.returnWait, execute: timeout)
        deliverIfReady()
    }

    func hostDidDisappear() {
        // Keep a pending dictation: disappearing is usually the trip to the voice
        // screen. It is cleared once delivered, or if nothing arrives on return.
        waitTimeout?.cancel()
        waitTimeout = nil
    }

    // MARK: Mic

    func micTapped() {
        guard let host else { return }
        guard host.voiceHasFullAccess, directory != nil else {
            showProblem("ভয়েস টাইপিংয়ের জন্য সেটিংসে Allow Full Access চালু করুন")
            return
        }
        host.voiceWillBeginDictation()
        let dictationID = String(UUID().uuidString.prefix(8)).lowercased()
        reconciler.begin(dictationID: dictationID, contextBefore: host.voiceDocument.contextBeforeInput)
        persistPending()
        log.notice("OBADH-VOICE opening the voice screen")
        host.voiceOpenContainingApp(VoiceSessionChannel.voiceURL(dictationID: dictationID)) { [weak self] opened in
            guard let self, !opened else { return }
            self.showProblem("অবাধ অ্যাপ খোলা যায়নি")
            self.clearPending()
        }
    }

    /// Kept for the controller's typing path: with no live dictation in the field,
    /// typing never competes with it.
    func finishBeforeTyping() {}

    // MARK: Delivery

    private func deliverIfReady() {
        guard reconciler.isActive, let host,
              let snapshot = readSnapshot(), snapshot.dictationID == reconciler.dictationID else { return }
        if let failure = snapshot.failure {
            showProblem(Self.message(for: failure))
            clearPending()
            return
        }
        guard snapshot.transcript.isFinal else { return }
        if let step = reconciler.step(for: snapshot) {
            host.voicePerformTextUpdate {
                if VoiceDraftWriter().apply(step, in: host.voiceDocument) == .stale {
                    // Nothing of ours is at the cursor to verify against; append the
                    // text where the cursor is.
                    let insertion = reconciler.fallbackInsertion(for: step)
                    if !insertion.isEmpty { host.voiceDocument.insertText(insertion) }
                }
            }
        }
        log.notice("OBADH-VOICE inserted \(snapshot.transcript.text.count, privacy: .public) chars")
        send(.acknowledge, dictationID: snapshot.dictationID ?? "")
        clearPending()
    }

    private func clearPending() {
        waitTimeout?.cancel()
        waitTimeout = nil
        reconciler.end()
        persistPending()
    }

    // MARK: Problems (the only words voice typing puts in the strip)

    private func showProblem(_ message: String) {
        host?.voiceShowIndicator(.problem(message))
        problemDismissal?.cancel()
        let dismissal = DispatchWorkItem { [weak self] in self?.host?.voiceShowIndicator(nil) }
        problemDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: dismissal)
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

    // MARK: Surviving the trip

    /// iOS often terminates the keyboard process while the user is in the app. The
    /// pending dictation (and where its text goes) is persisted, so the returning
    /// keyboard, a new process, still delivers it.
    private func persistPending() {
        if reconciler.isActive, let data = try? JSONEncoder().encode(reconciler) {
            persistence.set(data, forKey: Self.persistedKey)
        } else {
            persistence.removeObject(forKey: Self.persistedKey)
        }
    }

    private func restorePending() {
        guard !reconciler.isActive,
              let data = persistence.data(forKey: Self.persistedKey),
              let restored = try? JSONDecoder().decode(VoiceDraftReconciler.self, from: data) else { return }
        reconciler = restored
    }

    #if DEBUG
    /// `voice:problem|off` shows or clears a strip message, for reviewing on the
    /// simulator.
    func debugShowPanel(_ argument: String?) {
        switch argument {
        case "off": host?.voiceShowIndicator(nil)
        default: showProblem("অবাধ অ্যাপে ভয়েস মডেল ডাউনলোড করুন")
        }
    }
    #endif
}
