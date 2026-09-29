#if DEBUG
import SwiftUI
import UIKit

/// `--screen=voice-panel[:phase]`: the keyboard's suggestion strip in voice mode, on
/// the system keyboard material above placeholder key rows, driven by synthetic
/// levels. The Simulator will not reliably present a third-party keyboard, so this is
/// where the strip's look is reviewed. Uses the keyboard's own indicator view.
struct VoicePanelPreviewView: View {
    let phase: VoicePanelPhase
    private let feed: VoiceLevelFeed = {
        let feed = VoiceLevelFeed()
        feed.isSynthetic = true
        return feed
    }()

    var body: some View {
        ZStack(alignment: .bottom) {
            // Neutral, like most apps behind a keyboard.
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack(alignment: .leading) {
                    StripIndicator(phase: phase, feed: feed)
                    Image(systemName: phase == .listening || phase == .ready ? "mic.fill" : "mic")
                        .font(.system(size: 17))
                        .frame(width: 44)
                        .offset(y: -7)
                }
                .frame(height: 36)
                VStack(spacing: 11) {
                    ForEach(0..<4, id: \.self) { row in
                        HStack(spacing: 6) {
                            ForEach(0..<(row == 3 ? 3 : 10 - row), id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(.systemBackground).opacity(0.7))
                                    .frame(height: 44)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.top, 8)
            }
            .padding(.bottom, 30)
            .background(KeyboardMaterial().ignoresSafeArea())
        }
    }
}

private struct StripIndicator: UIViewRepresentable {
    let phase: VoicePanelPhase
    let feed: VoiceLevelFeed

    func makeUIView(context: Context) -> VoiceStripIndicatorView {
        let view = VoiceStripIndicatorView()
        view.levelFeed = feed
        return view
    }

    func updateUIView(_ view: VoiceStripIndicatorView, context: Context) {
        view.setPhase(phase, textColor: .secondaryLabel)
        // iPhone's strip puts its content 7pt above centre (see suggestionContentOffset).
        view.setContentOffset(-7)
    }
}

private struct KeyboardMaterial: UIViewRepresentable {
    func makeUIView(context: Context) -> UIInputView {
        UIInputView(frame: .zero, inputViewStyle: .keyboard)
    }
    func updateUIView(_ uiView: UIInputView, context: Context) {}
}
#endif
