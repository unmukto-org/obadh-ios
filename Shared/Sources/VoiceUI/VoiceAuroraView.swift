import SwiftUI

/// Where the listening visual gets its audio levels. The keyboard reads the shared
/// page the app writes; the app reads its own capture directly. Called once per
/// displayed frame, so it must be cheap.
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

/// The listening visual: glowing ribbons that follow the voice, drawn by
/// `VoiceAurora.metal`. Shared by the keyboard panel and the app's session screen.
struct VoiceAuroraView: View {
    let source: VoiceLevelSource
    /// Mutes the visual towards the breathing floor (e.g. while finishing).
    var isActive: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var smoother = SmootherBox()

    var body: some View {
        if reduceMotion {
            ReducedMotionGlow(source: source)
        } else {
            TimelineView(.animation) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                let state = smoother.advance(frame: isActive ? source.currentFrame() : .silent, time: time)
                Rectangle()
                    .fill(.white)
                    .colorEffect(
                        ShaderLibrary.voiceUI.voiceAurora(
                            .boundingRect,
                            .float(Float(time.truncatingRemainder(dividingBy: 3600))),
                            .float(state.level),
                            .float(state.energy),
                            .float(colorScheme == .dark ? 1 : 0),
                            // A float array arrives in the shader as pointer + count.
                            .floatArray(state.bands)
                        )
                    )
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Reference box so advancing the smoother inside the timeline closure does not
    /// invalidate the view (which would re-enter the body every frame).
    final class SmootherBox {
        private var smoother = VoiceLevelSmoother()
        func advance(frame: VoiceLevelFrame, time: Double) -> VoiceLevelSmoother {
            smoother.advance(to: frame, at: time)
            return smoother
        }
    }
}

/// Reduce Motion: no travelling waves, just a soft glow whose brightness follows the
/// voice.
private struct ReducedMotionGlow: View {
    let source: VoiceLevelSource
    @State private var box = VoiceAuroraView.SmootherBox()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20)) { context in
            let state = box.advance(frame: source.currentFrame(), time: context.date.timeIntervalSinceReferenceDate)
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [VoiceUIPalette.teal.opacity(0.55), VoiceUIPalette.violet.opacity(0.18), .clear],
                        center: .center, startRadius: 0, endRadius: 160
                    )
                )
                .scaleEffect(x: 1.6, y: 0.5 + 0.35 * Double(state.level))
                .opacity(0.45 + 0.55 * Double(state.level))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum VoiceUIPalette {
    static let teal = Color(red: 0x3C / 255, green: 0xBF / 255, blue: 0xBC / 255)
    static let deep = Color(red: 0x16 / 255, green: 0x50 / 255, blue: 0x6F / 255)
    static let sky = Color(red: 0x4F / 255, green: 0xA3 / 255, blue: 0xFF / 255)
    static let violet = Color(red: 0x8B / 255, green: 0x6C / 255, blue: 0xFF / 255)
}

/// The shader lives in whichever bundle compiled `VoiceAurora.metal`: the keyboard
/// extension or the app. `Bundle(for:)` on a class from this file finds it in both.
private final class VoiceUIBundleToken {}

extension ShaderLibrary {
    static var voiceUI: ShaderLibrary {
        ShaderLibrary.bundle(Bundle(for: VoiceUIBundleToken.self))
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

@MainActor
final class SyntheticVoiceLevelSource: VoiceLevelSource {
    func currentFrame() -> VoiceLevelFrame { SyntheticVoiceLevels.frame(at: CACurrentMediaTime()) }
}
#endif
