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
    private static weak var presented: VoiceKeyboardCoordinator?
    private var isPresented = false
    private var isDelivering = false

    /// The dictation this keyboard is waiting for, with where its text will go.
    private var reconciler = VoiceDraftReconciler()
    private var snapshotObserver: VoiceDarwinObserver?
    private var lastCommandSeq: UInt64 = 0
    private var waitTimeout: DispatchWorkItem?
    private var problemDismissal: DispatchWorkItem?

    private let persistence: UserDefaults
    private let directoryProvider: () -> URL?
    private static let persistedKey = "voice.keyboard.pendingDictation"
    /// A slow result gets a notice, not deletion of the pending dictation.
    private let returnWait: TimeInterval

    private var directory: URL? { directoryProvider() }

    init(persistence: UserDefaults = .standard, returnWait: TimeInterval = 6,
         directory: @escaping () -> URL? = { VoiceSessionChannel.directory() }) {
        self.persistence = persistence
        self.returnWait = returnWait
        directoryProvider = directory
    }

    // MARK: Lifecycle, driven by the controller

    func hostWillAppear() {
        restorePending()
    }

    func hostDidAppear() {
        Self.presented?.hostDidDisappear()
        Self.presented = self
        isPresented = true
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
            guard let self, self.isPresented, Self.presented === self else { return }
            self.restorePending()
            guard self.reconciler.isActive else { return }
            self.showProblem("ভয়েস লেখা তৈরি হচ্ছে। অবাধ অ্যাপে ফিরে দেখতে পারেন।")
        }
        waitTimeout?.cancel()
        waitTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + returnWait, execute: timeout)
        deliverIfReady()
    }

    func hostDidDisappear() {
        isPresented = false
        if Self.presented === self { Self.presented = nil }
        snapshotObserver = nil
        // Keep a pending dictation: disappearing is usually the trip to the voice
        // screen. A slow result remains pending until delivery or explicit editing.
        waitTimeout?.cancel()
        waitTimeout = nil
        problemDismissal?.cancel()
        problemDismissal = nil
    }

    // MARK: Mic

    func micTapped() {
        guard let host else { return }
        guard host.voiceHasFullAccess, directory != nil else {
            showProblem("ভয়েস টাইপিংয়ের জন্য সেটিংসে Allow Full Access চালু করুন")
            return
        }
        host.voiceWillBeginDictation()
        let dictationID = UUID().uuidString.lowercased()
        reconciler.begin(dictationID: dictationID, contextBefore: host.voiceDocument.contextBeforeInput)
        persistPending()
        // Disable delivery immediately, even before UIKit's disappearance callback.
        hostDidDisappear()
        log.notice("OBADH-VOICE opening the voice screen")
        host.voiceOpenContainingApp(VoiceSessionChannel.voiceURL(dictationID: dictationID)) { [weak self] opened in
            guard let self, !opened, self.pending()?.dictationID == dictationID else { return }
            self.showProblem("অবাধ অ্যাপ খোলা যায়নি")
            self.clearPending()
            self.hostDidAppear()
        }
    }

    /// Once the user starts editing again, a delayed result must not suddenly
    /// append to a changed field. The app keeps the unacknowledged text for Copy.
    func finishBeforeTyping() {
        guard isPresented, Self.presented === self else { return }
        restorePending()
        guard reconciler.isActive else { return }
        clearPending()
        showProblem("ভয়েস লেখা অবাধ অ্যাপে আছে। সেখান থেকে কপি করুন।")
    }

    // MARK: Delivery

    func deliverIfReady() {
        guard isPresented, Self.presented === self, !isDelivering else { return }
        // Another controller may already have delivered or begun a newer trip.
        restorePending()
        guard reconciler.isActive, let host,
              let snapshot = readSnapshot(), snapshot.dictationID == reconciler.dictationID else { return }
        if let failure = snapshot.failure {
            showProblem(Self.message(for: failure))
            clearPending()
            return
        }
        guard snapshot.transcript.isFinal else {
            // Cancel publishes an idle, empty tombstone for this exact trip.
            if snapshot.phase == .idle { clearPending() }
            return
        }
        isDelivering = true
        defer { isDelivering = false }
        let id = snapshot.dictationID ?? ""
        // Consume before proxy callbacks can reenter or a successor can restore it.
        // The app retains its copy until acknowledgement (including if we crash).
        persistence.removeObject(forKey: Self.persistedKey)
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
        send(.acknowledge, dictationID: id)
        clearPending()
    }

    private func clearPending() {
        waitTimeout?.cancel()
        waitTimeout = nil
        if pending()?.dictationID == reconciler.dictationID {
            persistence.removeObject(forKey: Self.persistedKey)
        }
        reconciler.end()
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
        case .audioOverflow, .finishTimedOut: "পুরো লেখা তৈরি হয়নি। অবাধ অ্যাপে ফিরে লেখা কপি করুন।"
        case .deliveryUnavailable: "লেখা পাঠানো যায়নি। অবাধ অ্যাপে ফিরে লেখা কপি করুন।"
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
        reconciler = pending() ?? VoiceDraftReconciler()
    }

    private func pending() -> VoiceDraftReconciler? {
        guard let data = persistence.data(forKey: Self.persistedKey) else { return nil }
        return try? JSONDecoder().decode(VoiceDraftReconciler.self, from: data)
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
