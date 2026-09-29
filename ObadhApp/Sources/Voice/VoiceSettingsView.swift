import AVFoundation
import SwiftUI

/// Settings › Voice Typing. Only what a person deciding whether and how to use voice
/// typing cares about: on or off, the one-time download, the microphone, and how
/// long it stays ready. Which models do the work is an implementation detail; their
/// credits live in About › Acknowledgements.
struct VoiceSettingsView: View {
    @ObservedObject var models: VoiceModelLibrary = .shared
    @ObservedObject var session: VoiceSessionController = .shared

    private let preferences = VoicePreferences()
    @State private var micButtonEnabled: Bool
    @State private var permission = AVAudioApplication.shared.recordPermission
    @State private var isConfirmingDelete = false

    init() {
        let preferences = VoicePreferences()
        _micButtonEnabled = State(initialValue: preferences.micButtonEnabled)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Voice Typing", isOn: $micButtonEnabled)
                    .onChange(of: micButtonEnabled) { _, value in preferences.micButtonEnabled = value }
            } footer: {
                Text("Tap the microphone on the Obadh keyboard and speak in Bangla.")
            }

            if micButtonEnabled {
                Section {
                    downloadRow
                    microphoneRow
                }
            }

            Section {
            } footer: {
                Text("The microphone is used only while you dictate with the Obadh keyboard. Voice typing works entirely on this iPhone; what you say never leaves it.")
            }
        }
        .navigationTitle("Voice Typing")
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            permission = AVAudioApplication.shared.recordPermission
        }
        .confirmationDialog("Remove Bangla voice?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { models.removeDefaultSet() }
        } message: {
            Text("Voice typing will need to download it again.")
        }
    }

    /// One row for the whole download, however many files and models it takes.
    @ViewBuilder private var downloadRow: some View {
        switch models.defaultSetStatus {
        case .installed(let bytes):
            LabeledContent("Bangla Voice", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .swipeActions {
                    Button("Remove", role: .destructive) { isConfirmingDelete = true }
                }
        case .downloading(let progress):
            HStack {
                Text("Bangla Voice")
                Spacer()
                ProgressView(value: progress)
                    .frame(width: 90)
                    .tint(VoiceUIPalette.teal)
            }
            .accessibilityValue("\(Int(progress * 100)) percent downloaded")
        case .notInstalled(let bytes):
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bangla Voice")
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Download") { models.downloadDefaultSet() }
                    .buttonStyle(.bordered)
                    .tint(VoiceUIPalette.teal)
            }
        case .failed:
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bangla Voice")
                    Text("Download didn't finish")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Try Again") { models.downloadDefaultSet() }
                    .buttonStyle(.bordered)
                    .tint(VoiceUIPalette.teal)
            }
        }
    }

    @ViewBuilder private var microphoneRow: some View {
        switch permission {
        case .granted:
            EmptyView()
        case .denied:
            Button("Allow Microphone in Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
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

}
