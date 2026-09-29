import Foundation

/// The wire format between the keyboard (which cannot record) and the containing app
/// (which records and recognizes). Both sides compile this file; see
/// docs/voice-typing.md for the channel table.
///
/// Every message is a whole JSON document written atomically, with a monotonic `seq`.
/// A Darwin notification only says "look again", so a duplicated, coalesced, or
/// dropped notification can never apply a message twice or out of order.
enum VoiceSessionPhase: String, Codable, Sendable {
    /// No engine running. The keyboard must bounce through the app to start one.
    case idle
    /// Engine running, models loading. Audio is already being buffered.
    case starting
    /// Engine running, not dictating. Every buffer is discarded.
    case ready
    /// Dictating: audio feeds the recognizers.
    case listening
    /// Dictation stopped; the last phrase is still being refined.
    case finishing
}

/// One phrase of a dictation, delimited by a pause.
struct VoiceSegment: Codable, Equatable, Sendable {
    let id: Int
    var text: String
    /// Settled segments will not change again: refined, or refinement was skipped
    /// or failed and the streaming text stands.
    var isSettled: Bool
}

struct VoiceSessionSnapshot: Codable, Equatable, Sendable {
    var seq: UInt64
    var phase: VoiceSessionPhase
    /// Refreshed at least once a second while the app process is alive. A stale
    /// heartbeat means the app was suspended or killed, whatever `phase` says.
    var heartbeat: Date
    /// The dictation the segments belong to, as issued by the keyboard.
    var dictationID: String?
    var segments: [VoiceSegment]
    /// When the warm session will close if nothing else happens.
    var expiresAt: Date?
    /// A short, user-presentable reason the last start failed, if it did.
    var failure: VoiceSessionFailure?
    /// Audio buffers are actually arriving (not just "the engine was started").
    /// The keyboard shows listening only while this is true.
    var isAudioFlowing: Bool? = nil
    /// The streaming recognizer has loaded. Before that, audio is buffered.
    var isRecognizerReady: Bool? = nil

    static let empty = VoiceSessionSnapshot(
        seq: 0,
        phase: .idle,
        heartbeat: .distantPast,
        dictationID: nil,
        segments: [],
        expiresAt: nil,
        failure: nil
    )

    /// Warm means a start command will be picked up without opening the app.
    func isWarm(now: Date = Date(), heartbeatTolerance: TimeInterval = VoiceSessionTiming.heartbeatTolerance) -> Bool {
        guard phase == .ready || phase == .listening || phase == .finishing || phase == .starting else {
            return false
        }
        return now.timeIntervalSince(heartbeat) <= heartbeatTolerance
    }
}

enum VoiceSessionFailure: String, Codable, Sendable {
    case microphonePermissionDenied
    case noStreamingModel
    case audioEngineFailed
    case interrupted
}

enum VoiceCommandKind: String, Codable, Sendable {
    /// Begin dictating into a new dictation id.
    case start
    /// Finish the open phrase, refine, settle, then return to ready.
    case stop
    /// Drop the dictation now; nothing more will be delivered for it.
    case cancel
    /// The keyboard has applied everything up to this dictation; the app may forget it.
    case acknowledge
    /// End the warm session entirely (the keyboard's "turn off" affordance).
    case endSession
}

struct VoiceCommand: Codable, Equatable, Sendable {
    var seq: UInt64
    var kind: VoiceCommandKind
    var dictationID: String
    var issuedAt: Date
}

enum VoiceSessionTiming {
    /// The app writes a heartbeat every second; allow for one missed beat plus
    /// scheduling jitter before calling the session cold.
    static let heartbeatTolerance: TimeInterval = 2.5
    static let heartbeatInterval: TimeInterval = 1.0
    /// How long the keyboard waits for a warm app to acknowledge a start before
    /// falling back to opening the app.
    static let warmStartAcknowledgementTimeout: TimeInterval = 0.6
    /// The longest "Done" waits for the last phrase to be refined before the
    /// keyboard settles for the streaming text.
    static let finishTimeout: TimeInterval = 4.0
    static let defaultWarmWindow: TimeInterval = 5 * 60
    static let warmWindowChoices: [TimeInterval] = [60, 5 * 60, 15 * 60, 60 * 60]
}

/// Names and places shared by both processes.
enum VoiceSessionChannel {
    static let snapshotDarwinName = "org.unmukto.obadh.voice.snapshot"
    static let commandDarwinName = "org.unmukto.obadh.voice.command"
    static let urlScheme = "obadh"
    static let urlHost = "voice"
    static let dictationQueryItem = "d"

    static func voiceURL(dictationID: String?) -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = urlHost
        if let dictationID {
            components.queryItems = [URLQueryItem(name: dictationQueryItem, value: dictationID)]
        }
        return components.url!
    }

    /// The directory inside the App Group container. nil when the container is
    /// unreachable: a keyboard without Full Access, or an unsigned simulator build.
    static func directory(fileManager: FileManager = .default) -> URL? {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: ObadhIdentity.appGroupID
        ) else { return nil }
        let directory = container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Voice", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func snapshotURL(in directory: URL) -> URL {
        directory.appendingPathComponent("session.json")
    }

    static func commandURL(in directory: URL) -> URL {
        directory.appendingPathComponent("command.json")
    }

    static func levelsURL(in directory: URL) -> URL {
        directory.appendingPathComponent("levels.bin")
    }
}

/// Atomic JSON persistence for the two message files.
enum VoiceMessageFile {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        // Complete-until-first-authentication so a locked phone does not make the
        // file unreadable to the other process mid-session.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? decoder.decode(type, from: data)
    }
}

/// Thin wrapper over the Darwin notify center. Payload-free by design.
enum VoiceDarwinNotifier {
    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }
}

/// Observes one Darwin notification name and calls `handler` on the main queue.
/// Removing the observer is tied to this object's lifetime.
final class VoiceDarwinObserver {
    private let name: String
    private let handler: @MainActor () -> Void

    init(name: String, handler: @escaping @MainActor () -> Void) {
        self.name = name
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let box = Unmanaged<VoiceDarwinObserver>.fromOpaque(observer).takeUnretainedValue()
                box.fire()
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString),
            nil
        )
    }

    private func fire() {
        let handler = self.handler
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler() }
        }
    }
}
