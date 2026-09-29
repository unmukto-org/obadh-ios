import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct ObadhVoiceControlsBundle: WidgetBundle {
    var body: some Widget {
        VoiceTypingControl()
        VoiceSessionLiveActivity()
    }
}

/// Control Center, Lock Screen, and Action button: turns voice typing on without
/// opening Obadh. After that, the keyboard's microphone works instantly in any app.
struct VoiceTypingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "org.unmukto.obadh.voice-typing") {
            ControlWidgetButton(action: StartVoiceSessionIntent()) {
                Label("Obadh Voice", systemImage: "mic.fill")
            }
        }
        .displayName("Obadh Voice Typing")
        .description("Turn on voice typing for the Obadh keyboard.")
    }
}

/// The Siri colours the keyboard's voice light uses, for the one animated glyph.
private let siriGradient = LinearGradient(
    colors: [
        Color(red: 1.00, green: 0.23, blue: 0.19),
        Color(red: 1.00, green: 0.62, blue: 0.04),
        Color(red: 0.75, green: 0.33, blue: 0.97),
        Color(red: 0.04, green: 0.52, blue: 1.00),
        Color(red: 0.35, green: 0.85, blue: 1.00)
    ],
    startPoint: .leading, endPoint: .trailing
)

/// The held microphone, visible wherever the user is. No timers: just what is
/// happening, and a way to turn it off.
struct VoiceSessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceSessionActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice Typing")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(context.state.isDictating ? "Listening" : "Ready in the Obadh keyboard")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Button(intent: EndVoiceSessionIntent()) {
                    Text("Turn Off")
                        .font(.subheadline.weight(.semibold))
                }
                .tint(.white.opacity(0.2))
            }
            .padding(16)
            .activityBackgroundTint(.black.opacity(0.6))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text("Voice Typing").font(.headline)
                        Text(context.state.isDictating ? "Listening" : "Ready in the Obadh keyboard")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: EndVoiceSessionIntent()) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 6)
                    .accessibilityLabel("Turn off voice typing")
                }
            } compactLeading: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.white)
            } compactTrailing: {
                WaveGlyph(isDictating: context.state.isDictating)
            } minimal: {
                WaveGlyph(isDictating: context.state.isDictating)
            }
        }
    }
}

/// Animates only while dictating, in the same Siri colours as the keyboard's light.
private struct WaveGlyph: View {
    let isDictating: Bool

    var body: some View {
        Image(systemName: "waveform")
            .foregroundStyle(isDictating ? AnyShapeStyle(siriGradient) : AnyShapeStyle(.white.opacity(0.5)))
            .symbolEffect(.variableColor.iterative.reversing, isActive: isDictating)
    }
}
