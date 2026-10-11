import SwiftUI

struct PrivacyView: View {
    @State private var isConfirmingClear = false
    @State private var didClear = false

    private let personalAutosuggestStore = PersonalAutosuggestStore()
    private let learnedWordStore = LearnedWordStore()

    var body: some View {
        Form {
            Section {
                paragraph(
                    "On your device",
                    "Transliteration, autocorrect, suggestions and emoji search all run inside the keyboard. The keyboard has no network access, so nothing you type can leave your device."
                )
                paragraph(
                    "Voice typing",
                    "Speech is recognized by models running on this iPhone. Audio is never recorded to storage or sent anywhere; each phrase is held in memory only until it is transcribed. The text passes from the app to the keyboard through Obadh's own container and is deleted once it reaches your text field. The one-time model download from Hugging Face is the only network request Obadh makes, and it carries nothing about you."
                )
                paragraph(
                    "What Obadh remembers",
                    "The emoji you use most recently, and the words you type — kept so suggestions improve as you write. Both are stored in Obadh's own container on this device."
                )
                paragraph(
                    "Full Access",
                    "iOS requires it before a keyboard may play typing sounds and haptics, read the settings you choose in this app, or open this app to start voice typing and receive the dictated text. Obadh uses it for nothing else. Granting it does not send anything anywhere."
                )
            }

            Section {
                Button("Clear Learned Words", role: .destructive) {
                    isConfirmingClear = true
                }
            } footer: {
                Text(didClear
                    ? "Learned words cleared. Obadh starts fresh the next time you type."
                    : "Removes the words Obadh has learned from your typing. Suggestions from the built-in dictionary are unaffected.")
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Clear learned words?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                personalAutosuggestStore.removeSnapshot()
                learnedWordStore.clear()
                withAnimation { didClear = true }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Obadh will forget everything it has learned from your typing. This can't be undone.")
        }
    }

    private func paragraph(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(body).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
