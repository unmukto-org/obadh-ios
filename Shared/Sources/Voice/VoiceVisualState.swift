import Foundation

/// What the keyboard shows while voice typing is active (in the suggestion strip).
enum VoicePanelPhase: Equatable {
    /// Waiting for the app: opening it, or a warm start not yet acknowledged.
    case connecting
    /// The app is recording; nothing heard yet in this dictation.
    case ready
    /// Speech is flowing.
    case listening
    /// Stopped; the last phrase is being refined.
    case finishing
    /// Something the user has to fix (shown as a short sentence).
    case problem(String)
}

/// Where the voice visual gets its audio levels, once per displayed frame. The
/// keyboard reads the shared page the app writes; the app reads the same page.
@MainActor
protocol VoiceLevelSource: AnyObject {
    func currentFrame() -> VoiceLevelFrame
}

/// Smooths raw levels into what the eye should see: a fast attack so syllables land
/// on the beat, a slower release so the light does not flicker between them, and a
/// much slower "presence" envelope that warms the colours while someone keeps talking.
struct VoiceLevelSmoother {
    private(set) var level: Float = 0
    private(set) var energy: Float = 0
    private(set) var bands = [Float](repeating: 0, count: VoiceLevelFrame.bandCount)
    private var lastTime: Double?

    mutating func advance(to frame: VoiceLevelFrame, at time: Double) {
        let dt = Float(min(max(time - (lastTime ?? time), 0), 0.1))
        lastTime = time
        func follow(_ current: Float, _ target: Float, attack: Float, release: Float) -> Float {
            let rate = target > current ? attack : release
            return current + (target - current) * min(1, dt * rate)
        }
        level = follow(level, frame.level, attack: 28, release: 7)
        energy = follow(energy, frame.isSpeech ? 1 : 0, attack: 1.6, release: 0.7)
        for index in bands.indices where index < frame.bands.count {
            bands[index] = follow(bands[index], frame.bands[index], attack: 22, release: 6)
        }
    }
}

#if DEBUG
/// Speech-like levels for reviewing the visual without a microphone: syllable-rate
/// bursts (~4 Hz) inside phrase-length envelopes with pauses, roughly what
/// conversational Bangla looks like to a level meter.
enum SyntheticVoiceLevels {
    static func frame(at time: Double) -> VoiceLevelFrame {
        let phrase = max(0, sin(time * 0.9)) > 0.15 ? 1.0 : 0.0
        let syllable = 0.5 + 0.5 * sin(time * 2 * .pi * 4.2) * sin(time * 2 * .pi * 1.3 + 1)
        let level = Float(phrase * (0.35 + 0.55 * syllable))
        let bands = (0..<VoiceLevelFrame.bandCount).map { index -> Float in
            let tilt = 1 - Float(index) / Float(VoiceLevelFrame.bandCount) * 0.7
            return level * tilt * Float(0.7 + 0.3 * sin(time * 3 + Double(index)))
        }
        return VoiceLevelFrame(level: level, isSpeech: phrase > 0, bands: bands, counter: UInt32(time * 60))
    }
}
#endif
