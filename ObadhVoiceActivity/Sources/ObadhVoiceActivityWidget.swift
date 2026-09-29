import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct ObadhVoiceActivityBundle: WidgetBundle {
    var body: some Widget {
        VoiceSessionActivityWidget()
    }
}

private let teal = Color(red: 0x3C / 255, green: 0xBF / 255, blue: 0xBC / 255)

/// The warm voice session in the Dynamic Island and on the Lock Screen. It exists
/// mainly so the user always knows the microphone is held, and can let it go.
struct VoiceSessionActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(teal)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Glyph(phase: context.state.phase, size: 26)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Countdown(state: context.state)
                        .font(.system(.body, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(title(for: context.state.phase))
                        .font(.system(.headline, design: .rounded))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(detail(for: context.state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                        Button(intent: EndVoiceSessionIntent()) {
                            Label("Turn Off", systemImage: "mic.slash.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .tint(teal)
                    }
                }
            } compactLeading: {
                Glyph(phase: context.state.phase, size: 14)
            } compactTrailing: {
                if context.state.phase == .listening {
                    Text("শুনছি")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(teal)
                } else {
                    Countdown(state: context.state)
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(teal)
                        .frame(maxWidth: 44)
                }
            } minimal: {
                Glyph(phase: context.state.phase, size: 13)
            }
            .keylineTint(teal)
        }
    }
}

private struct Glyph: View {
    let phase: VoiceActivityAttributes.ContentState.Phase
    let size: CGFloat

    var body: some View {
        Image(systemName: phase == .ready ? "mic.fill" : "waveform")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(teal)
            .symbolEffect(.variableColor.iterative.reversing, isActive: phase == .listening)
            .contentTransition(.symbolEffect(.replace))
    }
}

private struct Countdown: View {
    let state: VoiceActivityAttributes.ContentState

    var body: some View {
        if let expiresAt = state.expiresAt, expiresAt > .now {
            Text(timerInterval: Date.now...expiresAt, countsDown: true, showsHours: false)
                .multilineTextAlignment(.trailing)
        } else {
            Text(" ")
        }
    }
}

private struct LockScreenView: View {
    let state: VoiceActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            Glyph(phase: state.phase, size: 24)
                .frame(width: 44, height: 44)
                .background(teal.opacity(0.18), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: state.phase))
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)
                Text(detail(for: state))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
            }
            Spacer()
            Button(intent: EndVoiceSessionIntent()) {
                Image(systemName: "mic.slash.fill")
            }
            .tint(teal)
            .accessibilityLabel("Turn off voice typing")
        }
        .padding(16)
    }
}

private func title(for phase: VoiceActivityAttributes.ContentState.Phase) -> String {
    switch phase {
    case .ready: "Voice typing ready"
    case .listening: "Listening"
    case .finishing: "Finishing"
    }
}

private func detail(for state: VoiceActivityAttributes.ContentState) -> String {
    switch state.phase {
    case .ready:
        "Tap the mic on the Obadh keyboard to dictate. Nothing is heard until you do."
    case .listening:
        "Recognized on this iPhone. Audio never leaves it."
    case .finishing:
        "Tidying up the last phrase."
    }
}
