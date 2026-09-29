import SwiftUI
import UIKit

/// The app after setup: preferences, and nothing else. Setup guidance reappears only
/// when the keyboard is actually missing.
struct SettingsView: View {
    let install: KeyboardInstallState

    private let preferences = KeyboardPreferences()
    private let hapticPreview = UISelectionFeedbackGenerator()

    @State private var typingSoundsEnabled: Bool
    @State private var hapticFeedbackEnabled: Bool
    @State private var emojiSearchLanguage: EmojiSearchLanguage
    @State private var autoInsertTopCorrection: Bool

    init(install: KeyboardInstallState) {
        self.install = install
        let preferences = KeyboardPreferences()
        _typingSoundsEnabled = State(initialValue: preferences.typingSoundsEnabled)
        _hapticFeedbackEnabled = State(initialValue: preferences.hapticFeedbackEnabled)
        _emojiSearchLanguage = State(initialValue: preferences.defaultEmojiSearchLanguage)
        _autoInsertTopCorrection = State(initialValue: preferences.autoInsertTopCorrection)
    }

    /// Regular width means iPad, where a full-width form puts a toggle most of a
    /// foot from the label it belongs to — 1376pt apart on a 13-inch in landscape.
    /// A split view would be the other answer, but this screen is five rows; a
    /// sidebar for five rows is worse than the problem. So the form keeps a
    /// readable measure and centres, which is what it already does on a phone.
    @Environment(\.horizontalSizeClass) private var widthClass

    private static let readableFormWidth: CGFloat = 620

    var body: some View {
        NavigationStack {
            Form {
                if !install.isKeyboardInstalled {
                    keyboardMissingSection
                }
                keyboardSection
                voiceSection
                autocorrectSection
                emojiSection
                aboutSection
                #if DEBUG
                debugSection
                #endif
            }
            .frame(maxWidth: widthClass == .regular ? Self.readableFormWidth : .infinity)
            .frame(maxWidth: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Obadh")
            // A large title is laid out against the window's margins, so once the
            // form is centred the two no longer line up — the title sat 87pt left
            // of the content it belonged to. Centred inline title over centred
            // content reads as one thing. iPhone keeps the large title.
            .navigationBarTitleDisplayMode(widthClass == .regular ? .inline : .large)
        }
    }

    /// The only nag in the app, and it is load-bearing: without this the keyboard is
    /// simply gone and nothing else on this screen means anything.
    private var keyboardMissingSection: some View {
        Section {
            Button(action: openSystemSettings) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Obadh isn't in your keyboards")
                            .foregroundStyle(.primary)
                        Text("Open Settings › Keyboards to add it")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var keyboardSection: some View {
        Section {
            Toggle("Typing Sounds", isOn: $typingSoundsEnabled)
                .accessibilityIdentifier("typing-sounds-toggle")
                .onChange(of: typingSoundsEnabled) { _, enabled in
                    preferences.typingSoundsEnabled = enabled
                }
            Toggle("Haptic Feedback", isOn: $hapticFeedbackEnabled)
                .onChange(of: hapticFeedbackEnabled) { _, enabled in
                    preferences.hapticFeedbackEnabled = enabled
                    guard enabled else { return }
                    hapticPreview.prepare()
                    hapticPreview.selectionChanged()
                }
        } header: {
            Text("Keyboard")
        } footer: {
            Text("Typing sounds follow Silent Mode and Settings › Sounds & Haptics › Keyboard Feedback › Sound.")
            // Shown only while unconfirmed. The stamp is written by the extension, which
            // runs only when the user actually types — so granting Full Access and coming
            // straight back here leaves it unconfirmed, and saying "Obadh doesn't have it"
            // would be a claim we cannot make. Say what is true instead: it clears itself.
            if !install.isFullAccessConfirmed {
                Button(action: openSystemSettings) {
                    Text("Sounds and haptics need Full Access, granted in Settings › Keyboards. This clears once you've typed with Obadh.")
                        .font(.footnote)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var voiceSection: some View {
        Section {
            NavigationLink {
                VoiceSettingsView()
            } label: {
                Label("Voice Typing", systemImage: "mic")
            }
        } footer: {
            Text("Dictate in Bangla from the keyboard. Recognition runs on this iPhone.")
        }
    }

    private var autocorrectSection: some View {
        Section {
            Toggle("Auto-Insert Corrections", isOn: $autoInsertTopCorrection)
                .onChange(of: autoInsertTopCorrection) { _, enabled in
                    preferences.autoInsertTopCorrection = enabled
                }
        } header: {
            Text("Autocorrect")
        } footer: {
            Text("Space inserts likely corrections. Exact English loanwords always use their Bangla spelling, even when this is off. Tap the quoted spelling to keep the literal.")
        }
    }

    private var emojiSection: some View {
        Section("Emoji") {
            Picker("Search Language", selection: $emojiSearchLanguage) {
                Text("English").tag(EmojiSearchLanguage.english)
                Text("বাংলা").tag(EmojiSearchLanguage.bangla)
            }
            .onChange(of: emojiSearchLanguage) { _, language in
                preferences.defaultEmojiSearchLanguage = language
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            NavigationLink("Privacy") { PrivacyView() }
            // The full build stamp lives behind this row, not under it.
            NavigationLink {
                AboutView()
            } label: {
                LabeledContent(
                    "Version",
                    value: "\(AppBuildInfo.shortVersion) (\(AppBuildInfo.buildNumber))"
                )
            }
        }
    }

    #if DEBUG
    private var debugSection: some View {
        Section("Debug") {
            NavigationLink("Keyboard Test Field") {
                KeyboardTestScreen()
                    .navigationBarTitleDisplayMode(.inline)
                    .ignoresSafeArea(.keyboard)
            }
        }
    }
    #endif
}
