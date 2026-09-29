import SwiftUI

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
@MainActor
final class SyntheticVoiceLevelSource: VoiceLevelSource {
    func currentFrame() -> VoiceLevelFrame { SyntheticVoiceLevels.frame(at: CACurrentMediaTime()) }
}
#endif
