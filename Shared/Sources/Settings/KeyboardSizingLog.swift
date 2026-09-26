#if DEBUG
import Foundation

/// DEBUG-only recorder for the keyboard's sizing behavior, written by the keyboard
/// extension and read by the containing app's debug panel.
///
/// WHY IT EXISTS: the system's container band above the extension is composited
/// host-side, outside our window, so it is the one quantity the extension cannot
/// observe (verified: `view.window.bounds == view.bounds` on every measured
/// presentation). Everything that *is* observable — the sequence of heights the
/// system lays us out at, what we asked for, which presentation class we picked —
/// is recorded here so a device session produces evidence instead of recollection.
/// The band itself comes from a probe screenshot; `id` correlates the two.
///
/// Compile-excluded from Release: the shipping keyboard records nothing, anywhere.
/// No text, no host identity, and no keystrokes are captured — only geometry.
struct KeyboardSizingLog {
    struct Entry: Codable {
        /// Shown on the probe overlay as `#id`, so a screenshot (which carries the
        /// band) can be matched to the recorded presentation (which carries the rest).
        var id: Int
        var date: Date
        /// Process uptime in seconds when this presentation settled — the cold/warm
        /// start discriminant.
        var uptime: Double
        /// Presentation index within this extension process (1 = first since launch).
        var presentation: Int
        var pid: Int32
        /// Every distinct height the system laid us out at, in order. A `*` suffix
        /// marks a pass that arrived before `viewWillAppear`, which the shipping
        /// classifier cannot see.
        var trace: [String]
        /// The height our constraint asked for at settle.
        var ask: Double
        /// The suggestion strip we rendered.
        var strip: Double
        /// The height we actually settled at.
        var settled: Double
        /// "auto" (shipping detector) or the pinned class used instead.
        var mode: String
        /// The class in force at settle: banded / bandless / legacy.
        var presentationClass: String
        var screen: String
        var systemVersion: String
        var dark: Bool
        /// Heights observed AFTER the presentation settled — a late resize is
        /// invisible to the classifier and would show up here.
        var lateHeights: [Double]
        /// Actual laid-out strip, distinct from the requested metric. Optional so
        /// logs written by earlier builds remain readable.
        var actualStrip: Double? = nil
    }

    static let shared = KeyboardSizingLog()

    private let directoryName = "obadh-debug"
    private let fileName = "sizing.jsonl"
    private let maximumEntries = 400

    /// Same container resolution as KeyboardDebugChannel: the shared App Group on
    /// device, the extension's own Caches on the Simulator (where unsigned builds
    /// do not provision App Groups).
    private var fileURL: URL? {
        let fileManager = FileManager.default
        let base: URL
        if let group = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: KeyboardPreferences.appGroupIdentifier
        ) {
            base = group
        } else if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            base = caches
        } else {
            return nil
        }
        let directory = base.appendingPathComponent(directoryName, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Monotonic across processes so screenshot `#id` never repeats within a session.
    func nextIdentifier() -> Int {
        let defaults = UserDefaults(suiteName: KeyboardPreferences.appGroupIdentifier) ?? .standard
        let next = defaults.integer(forKey: "debug.sizingLogSeq") + 1
        defaults.set(next, forKey: "debug.sizingLogSeq")
        return next
    }

    func append(_ entry: Entry) {
        guard let fileURL, let data = try? encoder.encode(entry) else { return }
        var line = data
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: fileURL)
        }
        trimIfNeeded()
    }

    /// Rewrites the tail in place once the file grows past the cap, so a long
    /// session cannot fill the container.
    private func trimIfNeeded() {
        guard let fileURL,
              let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > maximumEntries else { return }
        let tail = lines.suffix(maximumEntries).joined(separator: "\n") + "\n"
        try? tail.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Newest first, for display. Undecodable lines are skipped rather than
    /// failing the whole read (the file is appended to from another process).
    func entries() -> [Entry] {
        guard let fileURL,
              let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
            .reversed()
    }

    func rawText() -> String {
        guard let fileURL,
              let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return "" }
        return text
    }

    func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Copies the log into the containing app's Documents so it can be pulled over
    /// USB (`xcrun devicectl device copy from … --domain-type appDataContainer`)
    /// without the share sheet. Call from the app, not the extension.
    @discardableResult
    func mirrorToAppDocuments() -> URL? {
        let text = rawText()
        guard !text.isEmpty,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return nil }
        let destination = documents.appendingPathComponent("obadh-sizing.jsonl")
        try? text.write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }
}
#endif
