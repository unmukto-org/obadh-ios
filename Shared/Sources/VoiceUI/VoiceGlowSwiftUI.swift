import SwiftUI
import UIKit

/// `VoiceGlowView` in SwiftUI, for the app's screens. The same view the keyboard's
/// strip uses, so the two can never drift apart visually.
struct VoiceGlow: UIViewRepresentable {
    let source: VoiceLevelSource
    var mode: VoiceGlowView.Mode = .live

    func makeUIView(context: Context) -> VoiceGlowView {
        let view = VoiceGlowView()
        view.levelSource = { [weak source] in source?.currentFrame() ?? .silent }
        view.setMode(mode)
        return view
    }

    func updateUIView(_ view: VoiceGlowView, context: Context) {
        view.setMode(mode)
    }
}

enum VoiceUIPalette {
    /// Obadh's own accent, for controls. The glow itself uses the Siri palette.
    static let teal = Color(red: 0x3C / 255, green: 0xBF / 255, blue: 0xBC / 255)
}

#if DEBUG
@MainActor
final class SyntheticVoiceLevelSource: VoiceLevelSource {
    func currentFrame() -> VoiceLevelFrame { SyntheticVoiceLevels.frame(at: CACurrentMediaTime()) }
}
#endif
