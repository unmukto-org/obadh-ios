import ActivityKit
import AppIntents
import Foundation

/// The warm voice session, as shown in the Dynamic Island and on the Lock Screen.
/// Compiled into the app (which starts and updates it) and the widget extension
/// (which draws it).
struct VoiceActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case ready, listening, finishing
        }

        var phase: Phase
        /// When the microphone will be released if nothing else happens. nil while
        /// dictating (the window restarts afterwards).
        var expiresAt: Date?
    }
}

/// "Turn off" from the Island or the Lock Screen. It talks to the session through
/// the same App Group command channel the keyboard uses, so it works whichever
/// process iOS runs it in.
struct EndVoiceSessionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Turn Off Voice Typing"
    static let description = IntentDescription("Releases the microphone Obadh holds for voice typing.")
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        guard let directory = VoiceSessionChannel.directory() else { return .result() }
        let command = VoiceCommand(
            seq: UInt64(Date().timeIntervalSince1970 * 1000),
            kind: .endSession,
            dictationID: "",
            issuedAt: Date()
        )
        try VoiceMessageFile.write(command, to: VoiceSessionChannel.commandURL(in: directory))
        VoiceDarwinNotifier.post(VoiceSessionChannel.commandDarwinName)
        return .result()
    }
}
