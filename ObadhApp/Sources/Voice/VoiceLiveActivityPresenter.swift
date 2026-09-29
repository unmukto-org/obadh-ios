import ActivityKit
import Foundation
import os

/// Drives the Live Activity for a warm session. A Live Activity can only be STARTED
/// from the foreground, which is exactly when a session starts (the keyboard's
/// bounce); updates and the end are allowed from the background while audio runs.
@MainActor
final class VoiceLiveActivityPresenter: VoiceActivityPresenting {
    static let shared = VoiceLiveActivityPresenter()

    private let log = Logger(subsystem: "org.unmukto.obadh", category: "voice")
    private var activity: Activity<VoiceActivityAttributes>?

    func sessionStarted(expiresAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endStaleActivities()
        let state = VoiceActivityAttributes.ContentState(phase: .ready, expiresAt: expiresAt)
        do {
            activity = try Activity.request(
                attributes: VoiceActivityAttributes(),
                content: .init(state: state, staleDate: expiresAt),
                pushType: nil
            )
        } catch {
            log.error("OBADH-VOICE live activity failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func phaseChanged(_ phase: VoiceSessionPhase, expiresAt: Date?) {
        guard let activity else { return }
        let mapped: VoiceActivityAttributes.ContentState.Phase = switch phase {
        case .listening: .listening
        case .finishing: .finishing
        default: .ready
        }
        let state = VoiceActivityAttributes.ContentState(phase: mapped, expiresAt: expiresAt)
        // `Activity` is not Sendable; this handle is only ever touched from the main
        // actor, and the update is the single use of it in flight.
        nonisolated(unsafe) let target = activity
        Task { await target.update(.init(state: state, staleDate: expiresAt)) }
    }

    func sessionEnded() {
        guard let activity else { return }
        self.activity = nil
        nonisolated(unsafe) let target = activity
        Task { await target.end(nil, dismissalPolicy: .immediate) }
    }

    /// An activity left over from a previous process (the app was killed mid-session)
    /// would show a microphone that is no longer held.
    func endStaleActivities() {
        for stale in Activity<VoiceActivityAttributes>.activities {
            nonisolated(unsafe) let target = stale
            Task { await target.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
