import SwiftUI

@MainActor
final class VoicePanelModel: ObservableObject {
    @Published var phase: VoicePanelPhase = .connecting
    var onDone: () -> Void = {}
    var onKeyboard: () -> Void = {}
}

/// Fills the key area while dictating. Deliberately sparse: the light is the
/// interface, the text is going straight into the field above, and there are exactly
/// two things to press.
struct VoicePanelView: View {
    @ObservedObject var model: VoicePanelModel
    let levels: VoiceLevelSource

    var body: some View {
        ZStack {
            VoiceAuroraView(source: levels, isActive: isLive)
                .padding(.horizontal, -8)

            VStack(spacing: 0) {
                statusLine
                    .padding(.top, 14)
                Spacer(minLength: 0)
                HStack {
                    keyboardButton
                    Spacer()
                    doneButton
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        // The panel sits where keys were: any tap on the light finishes, the same
        // way tapping the mic again would.
        .contentShape(Rectangle())
        .onTapGesture { if isLive { model.onDone() } }
        .animation(.smooth(duration: 0.25), value: model.phase)
    }

    private var isLive: Bool {
        switch model.phase {
        case .ready, .listening: true
        default: false
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch model.phase {
        case .connecting:
            label("অবাধ খুলছে…", systemImage: nil)
        case .ready:
            label("বলুন", systemImage: nil)
        case .listening:
            label("শুনছি", systemImage: nil)
        case .finishing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                label("গুছিয়ে নিচ্ছি…", systemImage: nil)
            }
        case .problem(let message):
            label(message, systemImage: "exclamationmark.circle")
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private func label(_ text: String, systemImage: String?) -> some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.secondary)
        .transition(.opacity)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var keyboardButton: some View {
        Button(action: model.onKeyboard) {
            Image(systemName: "keyboard")
                .font(.system(size: 19, weight: .regular))
                .frame(width: 46, height: 46)
        }
        .buttonStyle(VoiceGlassButtonStyle(shape: .circle))
        .accessibilityLabel("Return to keyboard")
    }

    private var doneButton: some View {
        Button(action: model.onDone) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                Text("সম্পন্ন")
                    .font(.system(size: 16, weight: .semibold))
            }
            .padding(.horizontal, 18)
            .frame(height: 46)
        }
        .buttonStyle(VoiceGlassButtonStyle(shape: .capsule, tint: VoiceUIPalette.teal))
        .disabled(!isLive)
        .opacity(isLive ? 1 : 0.5)
        .accessibilityLabel("Done")
    }
}

/// Liquid Glass on iOS 26+, a material chip below it, so the controls match the
/// keys around them on every supported OS.
struct VoiceGlassButtonStyle: ButtonStyle {
    enum Shape { case circle, capsule }
    let shape: Shape
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .foregroundStyle(tint == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
        if #available(iOS 26.0, *) {
            switch shape {
            case .circle:
                label.glassEffect(glass, in: .circle)
            case .capsule:
                label.glassEffect(glass, in: .capsule)
            }
        } else {
            switch shape {
            case .circle:
                label.background(fallbackFill, in: Circle())
            case .capsule:
                label.background(fallbackFill, in: Capsule())
            }
        }
    }

    @available(iOS 26.0, *)
    private var glass: Glass {
        var glass = Glass.regular.interactive()
        if let tint { glass = glass.tint(tint) }
        return glass
    }

    private var fallbackFill: AnyShapeStyle {
        if let tint { return AnyShapeStyle(tint) }
        return AnyShapeStyle(.regularMaterial)
    }
}
