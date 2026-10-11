import SwiftUI
import UIKit

/// `VoiceLensView` in SwiftUI, for the app's screens: the same lens the keyboard's
/// strip shows, so the two can never drift apart visually.
struct VoiceLens: UIViewRepresentable {
    let feed: VoiceLevelFeed
    var mode: VoiceLensView.Mode = .live

    func makeUIView(context: Context) -> VoiceLensView {
        let view = VoiceLensView()
        view.levelFeed = feed
        view.setMode(mode)
        return view
    }

    func updateUIView(_ view: VoiceLensView, context: Context) {
        view.setMode(mode)
    }
}

enum VoiceUIPalette {
    /// Obadh's own accent, for controls. The lens itself uses the Siri palette.
    static let teal = Color(red: 0x3C / 255, green: 0xBF / 255, blue: 0xBC / 255)
}
