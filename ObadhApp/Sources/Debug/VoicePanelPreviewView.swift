#if DEBUG
import SwiftUI
import UIKit

/// `--screen=voice-panel[:phase]`: the keyboard's voice panel at keyboard size over
/// the system keyboard material, driven by synthetic levels. The Simulator will not
/// reliably present a third-party keyboard, so this is where the visual is reviewed.
struct VoicePanelPreviewView: View {
    @StateObject private var model = VoicePanelModel()
    private let source = SyntheticVoiceLevelSource()
    let phase: VoicePanelPhase

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [.pink, .orange, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                // Stand-in strip with the mic, as the keyboard draws it while listening.
                HStack {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(VoiceUIPalette.teal)
                        .frame(width: 44)
                    Spacer()
                }
                .frame(height: 44)
                VoicePanelView(model: model, levels: source)
                    .frame(height: 216)
            }
            .padding(.bottom, 34)
            .background(KeyboardMaterial().ignoresSafeArea())
        }
        .onAppear { model.phase = phase }
    }
}

private struct KeyboardMaterial: UIViewRepresentable {
    func makeUIView(context: Context) -> UIInputView {
        UIInputView(frame: .zero, inputViewStyle: .keyboard)
    }
    func updateUIView(_ uiView: UIInputView, context: Context) {}
}
#endif
