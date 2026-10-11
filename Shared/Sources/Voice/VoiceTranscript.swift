import Foundation

/// A dictation's text as the app publishes it: the whole text so far, of which the
/// first `stableLength` characters are committed and will never change.
///
/// Committed text only ever grows at its end, so the keyboard appends it without
/// deleting or verifying anything in the host app. Only the tail after it (usually
/// the last word, which the recognizer may still revise) is tentative and can be
/// rewritten.
struct VoiceTranscript: Codable, Equatable, Sendable {
    var text: String
    /// Characters (grapheme clusters) of `text` that are committed.
    var stableLength: Int
    /// The dictation is over: everything is committed.
    var isFinal: Bool

    static let empty = VoiceTranscript(text: "", stableLength: 0, isFinal: false)

    var stableText: Substring { text.prefix(stableLength) }
}

/// Builds `VoiceTranscript`s from what the streaming recognizer reports.
///
/// Policy, the standard stable-prefix scheme for streaming recognition:
/// * hold back the last word of the open phrase (it may still grow or change);
/// * local agreement (LA-2): commit a word only once two consecutive hypotheses
///   agree on it, so a one-off revision is never committed;
/// * a pause, a closed phrase, or the end of the dictation commits everything.
/// Committed words are frozen here, so even a revision the policy did not expect can
/// never change text the keyboard has already appended.
struct VoiceTranscriptBuilder: Equatable {
    private(set) var frozen: [String] = []
    private var closed: [String] = []
    private var open: [String] = []
    /// The previous hypothesis of the open phrase, for local agreement.
    private var previousOpen: [String] = []
    private var isFinal = false

    /// The recognizer's current reading of the phrase being spoken.
    mutating func setOpenPhrase(_ hypothesis: String) {
        previousOpen = open
        open = Self.words(hypothesis)
        refreeze(everything: false)
    }

    /// The phrase ended (a pause): its final reading is committed in full.
    mutating func closeOpenPhrase(final hypothesis: String) {
        closed += Self.words(hypothesis)
        open = []
        previousOpen = []
        refreeze(everything: true)
    }

    /// A pause: every word so far is committed, while the recognizer keeps running
    /// (its text keeps growing from here, and `setOpenPhrase` keeps receiving it).
    mutating func commitAll() {
        refreeze(everything: true)
    }

    /// The dictation ended: everything is committed.
    mutating func finish() {
        closed += open
        open = []
        refreeze(everything: true)
        isFinal = true
    }

    var transcript: VoiceTranscript {
        let current = closed + open
        let tail = current.count > frozen.count ? Array(current[frozen.count...]) : []
        let words = frozen + tail
        let stable = frozen.joined(separator: " ")
        return VoiceTranscript(text: words.joined(separator: " "), stableLength: stable.count, isFinal: isFinal)
    }

    private mutating func refreeze(everything: Bool) {
        let current = closed + open
        let target: Int
        if everything {
            target = current.count
        } else {
            // Hold back the last word, and commit only what the previous hypothesis
            // agreed on word for word (LA-2).
            var agreed = 0
            while agreed < min(open.count - 1, previousOpen.count), open[agreed] == previousOpen[agreed] {
                agreed += 1
            }
            target = closed.count + max(0, agreed)
        }
        guard target > frozen.count else { return }
        frozen += current[frozen.count..<target]
    }

    /// NFC, split on whitespace.
    static func words(_ text: String) -> [String] {
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}
