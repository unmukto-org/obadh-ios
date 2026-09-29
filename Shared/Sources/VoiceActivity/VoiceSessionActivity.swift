import ActivityKit
import AppIntents
import Foundation

/// The voice session as a Live Activity. iOS requires one while an audio-recording
/// intent (Control Center, Lock Screen, Action button) keeps recording; Obadh shows
/// the same one for every session so a held microphone always looks the same: a
/// badge, and a way to turn it off. Compiled into the app and the widget extension.
struct VoiceSessionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isDictating: Bool
    }
}

/// Starts a voice session from Control Center, the Lock Screen, or the Action button,
/// without opening Obadh. As an `AudioRecordingIntent` it runs in the app's process
/// in the background, the one sanctioned way to start the microphone there. Once the
/// session runs, the keyboard's mic dictates instantly in any app.
struct StartVoiceSessionIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Start Voice Typing"
    static let description = IntentDescription("Turns on Obadh voice typing so the keyboard's microphone works right away.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        #if OBADH_APP
        try await VoiceSessionIntentBridge.start()
        #endif
        return .result()
    }
}

/// Ends the session: the Live Activity's Turn Off button. It sends the same App Group
/// command the keyboard uses, so it works whichever process iOS runs it in.
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
