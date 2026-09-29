import ActivityKit
import Foundation
import os

/// The session's Live Activity: started with the session, ended with it.
///
/// For a session started by the recording intent this is required by iOS, and
/// allowed from the background because the intent is running. For a session started
/// by the keyboard's bounce the app is in front, which also allows it.
@MainActor
final class VoiceLiveActivityPresenter {
    static let shared = VoiceLiveActivityPresenter()

    private let log = Logger(subsystem: "org.unmukto.obadh", category: "voice")
    private var activity: Activity<VoiceSessionActivityAttributes>?
    private var lastState: VoiceSessionActivityAttributes.ContentState?

    func sessionStarted() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.notice("OBADH-VOICE live activities are off for Obadh")
            return
        }
        endStale()
        let state = VoiceSessionActivityAttributes.ContentState(isDictating: false)
        do {
            activity = try Activity.request(
                attributes: VoiceSessionActivityAttributes(),
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            lastState = state
            log.notice("OBADH-VOICE live activity started")
        } catch {
            log.error("OBADH-VOICE live activity failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func dictationChanged(isDictating: Bool) {
        guard let activity else { return }
        let state = VoiceSessionActivityAttributes.ContentState(isDictating: isDictating)
        guard state != lastState else { return }
        lastState = state
        // `Activity` is not Sendable; this handle is only touched from the main actor.
        nonisolated(unsafe) let target = activity
        Task { await target.update(.init(state: state, staleDate: nil)) }
    }

    func sessionEnded() {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        nonisolated(unsafe) let target = activity
        Task { await target.end(nil, dismissalPolicy: .immediate) }
    }

    /// A fresh process holds no microphone: any leftover activity is from a process
    /// that was killed.
    func endStale() {
        for stale in Activity<VoiceSessionActivityAttributes>.activities where stale.id != activity?.id {
            nonisolated(unsafe) let target = stale
            Task { await target.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
