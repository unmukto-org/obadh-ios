import AudioToolbox
import CoreHaptics
import UIKit

/// Key-press haptics tuned to Apple's own keyboard: a single, crisp "tick". The
/// exact system pattern is private, so we reproduce its *character* — a
/// high-sharpness transient — via Core Haptics (the only public API exposing the
/// sharpness/crispness axis). Below that we fall back to a `.rigid` impact (the
/// snappiest `UIImpactFeedbackGenerator` preset).
///
/// The native keyboard plays essentially ONE uniform tick for every printing key,
/// so this is a single transient — **intensity 0.5 / sharpness 0.9** — dialed in
/// on-device by the product owner to match Apple's keyboard. High sharpness keeps
/// it a definite tick (not a mush); moderate intensity keeps it from feeling
/// heavy. The emoji/globe language key stays silent, mirroring the native
/// keyboard; a word/sentence backspace is a touch firmer as a "larger delete"
/// cue. Haptics require Full Access and the user's system haptic setting; the
/// controller degrades to silence when either is missing.
@MainActor
final class KeyboardFeedbackController {
    /// Fallback impact generator (used when Core Haptics is unavailable).
    private let rigidFeedback = UIImpactFeedbackGenerator(style: .rigid)

    private let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var engine: CHHapticEngine?

    private let preferences: KeyboardPreferences
    private let requestSystemClick: (KeyboardClickSound) -> Void
    private var typingSoundsEnabled = true

    /// Shared by the input view's audio opt-in and every feedback entry point.
    /// The UIKit input click retains its visibility/system-preference gate.
    /// Direct modifier/delete playback still requires hardware policy acceptance.
    var inputClicksEnabled: Bool { fullAccessGranted && typingSoundsEnabled }

    init(
        preferences: KeyboardPreferences = KeyboardPreferences(),
        requestSystemClick: @escaping (KeyboardClickSound) -> Void = { sound in
            switch sound {
            case .input: UIDevice.current.playInputClick()
            // Undocumented IDs, matched by the owner in Sound Probe 151.
            // Candidate only: system Sound-off behavior still needs verification.
            case .delete: AudioServicesPlaySystemSound(1155)
            case .modifier: AudioServicesPlaySystemSound(1156)
            }
        }
    ) {
        self.preferences = preferences
        self.requestSystemClick = requestSystemClick
    }
    private var hapticFeedbackEnabled = true

    /// Core Haptics needs Full Access: a sandboxed extension without it cannot reach
    /// the haptic server. The controller must be TOLD, because without this it kept
    /// retrying and each attempt blocked the main thread.
    private var fullAccessGranted = false

    /// Set once engine creation has failed, and never retried for the lifetime of the
    /// controller.
    ///
    /// WHY THIS EXISTS: `emit()` falls through to `startEngine()` whenever `engine` is
    /// nil, so with Full Access off — a fully supported configuration — every single
    /// keystroke constructed a `CHHapticEngine` and called the synchronous
    /// `engine.start()`, which fails slowly. Measured on an iPhone 16e: main-thread
    /// stalls up to **3.7 seconds** and 220 dropped frames in a single second, while
    /// every instrumented path (keystroke 1.1ms, textDidChange, selectionDidChange,
    /// refreshSuggestions) stayed under 8ms. The keyboard was unusable and the cause
    /// was a haptic engine that could never start.
    private var engineUnavailable = false

    /// One crisp transient: intensity + sharpness (each 0…1), plus the intensity
    /// to use for the `.rigid` impact fallback.
    private struct Tick {
        let intensity: Float
        let sharpness: Float
        let fallbackIntensity: CGFloat

        init(_ intensity: Float, _ sharpness: Float, fallback: CGFloat) {
            self.intensity = intensity
            self.sharpness = sharpness
            self.fallbackIntensity = fallback
        }
    }

    /// The shipped key-press tick (owner-tuned on-device to match native).
    private static let standardTick = Tick(0.5, 0.9, fallback: 0.55)

    // MARK: Lifecycle

    /// `hasFullAccess` comes from the input view controller; Core Haptics is
    /// unreachable without it.
    func prepare(hasFullAccess: Bool) {
        if hasFullAccess, !fullAccessGranted {
            // Newly granted: it is worth one more attempt.
            engineUnavailable = false
        }
        fullAccessGranted = hasFullAccess
        reloadPreferences()
        rigidFeedback.prepare()
        startEngine()
    }

    func reloadPreferences() {
        hapticFeedbackEnabled = preferences.hapticFeedbackEnabled
        typingSoundsEnabled = preferences.typingSoundsEnabled
    }

    /// Starts the engine ASYNCHRONOUSLY and at most once. Both guards matter: the
    /// synchronous `start()` blocks the main thread, and a single failure means it
    /// will keep failing, so retrying per keystroke only multiplies the stall.
    private func startEngine() {
        guard supportsHaptics, hapticFeedbackEnabled, fullAccessGranted,
              !engineUnavailable, engine == nil else { return }
        do {
            let created = try CHHapticEngine()
            created.isAutoShutdownEnabled = true
            created.stoppedHandler = { [weak self] _ in
                Task { @MainActor in self?.engine = nil }
            }
            created.resetHandler = { [weak self] in
                Task { @MainActor in self?.engine?.start(completionHandler: { _ in }) }
            }
            // Held before starting so the completion handler never has to send a
            // non-Sendable engine across an isolation boundary; until the start
            // succeeds a play() simply throws and emit() falls back to the impact.
            engine = created
            // Async start: the synchronous variant is what blocked the main thread.
            created.start { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    guard error == nil else {
                        self.engine = nil
                        self.engineUnavailable = true
                        return
                    }
                    // Prewarm with an imperceptible zero-intensity transient so the
                    // first real key tap doesn't pay the cold-start latency.
                    try? self.play(intensity: 0, sharpness: 0)
                }
            }
        } catch {
            engine = nil
            engineUnavailable = true
        }
    }

    // MARK: Public API

    func keyTouched(_ key: KeyboardKey) {
        // One uniform tick for every printing key; the emoji/globe language key
        // stays silent, matching Apple's own keyboard.
        if hapticFeedbackEnabled, key != .emoji {
            emit(Self.standardTick)
        }
        playInputClick(KeyboardClickSound(key: key))
    }

    func suggestionAccepted() {
        if hapticFeedbackEnabled {
            emit(Self.standardTick)
        }
        playInputClick(.input)
    }

    func backspaceRepeated(unit: BackspaceDeletionUnit) {
        if hapticFeedbackEnabled {
            switch unit {
            case .character:
                emit(Self.standardTick)
            case .word, .sentence, .availableContext:
                emit(Tick(0.6, 0.9, fallback: 0.65)) // a touch firmer for a larger delete
            }
        }
        playInputClick(.delete)
    }

    // MARK: Playback

    private func playInputClick(_ sound: KeyboardClickSound) {
        guard inputClicksEnabled else { return }
        // No custom audio session, duplicate click or per-key volume adjustment.
        requestSystemClick(sound)
    }

    private func emit(_ tick: Tick) {
        var tick = tick
        #if DEBUG
        // Live tuning: when the app's debug sliders are engaged, every tick uses
        // the same dialed-in intensity/sharpness so the feel can be matched on
        // hardware. Read fresh each keystroke to pick up slider changes.
        let prefs = KeyboardPreferences()
        if prefs.debugHapticOverrideEnabled {
            tick = Tick(
                Float(prefs.debugHapticIntensity),
                Float(prefs.debugHapticSharpness),
                fallback: CGFloat(prefs.debugHapticIntensity)
            )
        }
        #endif
        if supportsHaptics, engine != nil {
            do {
                try play(intensity: tick.intensity, sharpness: tick.sharpness)
                return
            } catch {
                engine = nil // died between taps
            }
        }
        rigidFeedback.impactOccurred(intensity: tick.fallbackIntensity)
        rigidFeedback.prepare()
        // Deliberately NOT relighting the engine here. This is the keystroke path, and
        // startEngine() used to run on it: with Full Access off it constructed and
        // synchronously started an engine that could never work, once per keypress.
        // Relighting is now driven by prepare() at presentation instead.
    }

    private func play(intensity: Float, sharpness: Float) throws {
        guard let engine else { return }
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: 0
        )
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        let player = try engine.makePlayer(with: pattern)
        try player.start(atTime: CHHapticTimeImmediate)
    }
}
