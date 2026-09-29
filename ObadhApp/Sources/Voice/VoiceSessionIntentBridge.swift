import Foundation

/// App-side body of `StartVoiceSessionIntent`.
enum VoiceSessionIntentBridge {
    enum StartError: Error, CustomLocalizedStringResourceConvertible {
        case couldNotStart

        var localizedStringResource: LocalizedStringResource {
            "Open Obadh once to allow the microphone and download Bangla Voice."
        }
    }

    @MainActor
    static func start() async throws {
        let session = VoiceSessionController.shared
        guard await session.startSession(thenDictate: nil, source: .systemIntent) else {
            throw StartError.couldNotStart
        }
    }
}
