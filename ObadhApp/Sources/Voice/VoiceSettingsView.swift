import AVFoundation
import SwiftUI

/// Settings › Voice Typing: models, microphone, and how long the mic stays ready.
struct VoiceSettingsView: View {
    @ObservedObject var models: VoiceModelLibrary = .shared
    @ObservedObject var session: VoiceSessionController = .shared

    private let preferences = VoicePreferences()
    @State private var micButtonEnabled: Bool
    @State private var refinementEnabled: Bool
    @State private var warmWindow: TimeInterval
    @State private var permission = AVAudioApplication.shared.recordPermission

    init() {
        let preferences = VoicePreferences()
        _micButtonEnabled = State(initialValue: preferences.micButtonEnabled)
        _refinementEnabled = State(initialValue: preferences.refinementEnabled)
        _warmWindow = State(initialValue: preferences.warmWindow)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Mic on the Keyboard", isOn: $micButtonEnabled)
                    .onChange(of: micButtonEnabled) { _, value in preferences.micButtonEnabled = value }
                microphoneRow
            } footer: {
                Text("Tap the mic at the left of the suggestion bar. The first time in a while, Obadh opens briefly to start the microphone; tap ◀ at the top left to go back and keep talking.")
            }

            modelSection(role: .streaming, header: "Live Draft", footer: "Shows your words as you speak.")
            modelSection(role: .refiner, header: "Accuracy Pass", footer: "Re-reads each phrase when you pause and corrects the draft.")

            Section {
                Toggle("Accuracy Pass", isOn: $refinementEnabled)
                    .onChange(of: refinementEnabled) { _, value in preferences.refinementEnabled = value }
                Picker("Keep Microphone Ready", selection: $warmWindow) {
                    ForEach(VoiceSessionTiming.warmWindowChoices, id: \.self) { seconds in
                        Text(Self.label(for: seconds)).tag(seconds)
                    }
                }
                .onChange(of: warmWindow) { _, value in preferences.warmWindow = value }
                if session.phase != .idle {
                    Button("Turn Off Microphone Now", role: .destructive) { session.endSession() }
                }
            } footer: {
                Text("While ready, the microphone indicator stays on so the next dictation starts instantly. Nothing is heard or kept until you tap the mic.")
            }

            Section {
                Text("Speech is recognized entirely on this iPhone. Audio and text never leave it, and nothing is stored after it reaches your text field. Models are downloaded once from Hugging Face; the download is the only network request voice typing makes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Voice Typing")
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            permission = AVAudioApplication.shared.recordPermission
        }
    }

    @ViewBuilder private var microphoneRow: some View {
        switch permission {
        case .granted:
            LabeledContent("Microphone", value: "Allowed")
        case .denied:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                LabeledContent("Microphone", value: "Off: Open Settings")
            }
        default:
            Button("Allow Microphone") {
                Task {
                    _ = await AVAudioApplication.requestRecordPermission()
                    permission = AVAudioApplication.shared.recordPermission
                }
            }
        }
    }

    private func modelSection(role: VoiceModelRole, header: String, footer: String) -> some View {
        Section {
            ForEach(models.models(for: role)) { model in
                VoiceModelRow(model: model, models: models)
            }
        } header: {
            Text(header)
        } footer: {
            Text(footer)
        }
    }

    private static func label(for seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "1 Hour" : "\(minutes) Minute\(minutes == 1 ? "" : "s")"
    }
}

private struct VoiceModelRow: View {
    let model: VoiceModelDescriptor
    @ObservedObject var models: VoiceModelLibrary

    private var isActive: Bool {
        model.id == (model.role == .streaming ? models.activeStreamingID : models.activeRefinerID)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayName)
                Text("\(ByteCountFormatter.string(fromByteCount: model.totalBytes, countStyle: .file)) · \(model.license)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .failed(let message) = models.state(of: model) {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            trailing
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if models.state(of: model) == .installed { models.setActive(model) }
        }
        .swipeActions {
            if models.state(of: model) == .installed {
                Button("Delete", role: .destructive) { models.remove(model) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    @ViewBuilder private var trailing: some View {
        switch models.state(of: model) {
        case .installed:
            if isActive {
                Image(systemName: "checkmark").foregroundStyle(VoiceUIPalette.teal).fontWeight(.semibold)
            }
        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress).frame(width: 64).tint(VoiceUIPalette.teal)
                Button { models.cancelDownload(model) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Cancel download")
            }
        case .notInstalled, .failed:
            Button("Get") { models.download(model) }
                .buttonStyle(.bordered)
                .tint(VoiceUIPalette.teal)
        }
    }
}
