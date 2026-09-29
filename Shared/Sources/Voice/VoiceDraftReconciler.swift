import Foundation

/// Turns the app's transcript snapshots into document edits, keyboard side.
///
/// The document holds the dictation as ordinary text. Settled phrases are left
/// alone for good; only the unsettled tail (the phrase being spoken plus any phrase
/// still waiting for the refiner) is tracked and rewritten in place. Because the
/// app refines phrases in order, settled phrases are always a prefix, so the tracked
/// region is always the text immediately before the cursor.
///
/// This type is pure: it decides what the tracked region should read, and how much
/// of it to let go of afterwards. `VoiceDraftWriter` applies that to a live document.
struct VoiceDraftReconciler: Equatable {
    struct Step: Equatable {
        /// What the tracked region reads now (as last applied).
        let currentText: String
        /// What it should read.
        let desiredText: String
        /// After applying `desiredText`, how much of it stays tracked. Always a suffix
        /// of `desiredText`; the rest has settled and is released.
        let retainedText: String
        /// Everything in the snapshot is settled; the dictation is complete.
        let completesDictation: Bool
    }

    private(set) var dictationID: String?
    /// Segments with an id at or below this are released (settled and applied, or
    /// abandoned because the tracked text was lost).
    private(set) var releasedThroughID = -1
    /// Whether any text of this dictation has been released into the document, which
    /// means the next phrase needs a separating space.
    private(set) var hasReleasedText = false
    /// Exact text currently tracked in the document.
    private(set) var trackedText = ""
    /// Separator to put before the very first phrase, decided at `begin` from what
    /// precedes the cursor.
    private(set) var leadingSeparator = ""

    var isActive: Bool { dictationID != nil }

    mutating func begin(dictationID: String, contextBefore: String?) {
        self = VoiceDraftReconciler()
        self.dictationID = dictationID
        leadingSeparator = Self.separator(after: contextBefore ?? "")
    }

    mutating func end() {
        self = VoiceDraftReconciler()
    }

    /// The edit a snapshot calls for, or nil when there is nothing to do.
    func step(for snapshot: VoiceSessionSnapshot) -> Step? {
        guard let dictationID, snapshot.dictationID == dictationID else { return nil }

        let pending = snapshot.segments
            .filter { $0.id > releasedThroughID }
            .sorted { $0.id < $1.id }

        let desired = compose(pending)
        let settledPrefix = pending.prefix { $0.isSettled }
        let unsettled = pending.dropFirst(settledPrefix.count)
        let allSettled = unsettled.isEmpty
            && (snapshot.phase == .ready || snapshot.phase == .idle)

        // What remains tracked is the unsettled tail, rendered exactly as `compose`
        // renders it inside `desired`, so it is a true suffix.
        let retained: String
        if unsettled.contains(where: { !$0.text.isEmpty }) {
            let releasedAnything = hasReleasedText || settledPrefix.contains { !$0.text.isEmpty }
            retained = Self.join(Array(unsettled), prefix: releasedAnything ? " " : leadingSeparator)
        } else {
            retained = ""
        }

        if desired == trackedText, retained == trackedText, settledPrefix.isEmpty, !allSettled {
            return nil
        }
        return Step(
            currentText: trackedText,
            desiredText: desired,
            retainedText: retained,
            completesDictation: allSettled
        )
    }

    /// Record that `step` was applied to the document.
    mutating func didApply(_ step: Step, snapshot: VoiceSessionSnapshot) {
        let pending = snapshot.segments
            .filter { $0.id > releasedThroughID }
            .sorted { $0.id < $1.id }
        let settledPrefix = pending.prefix { $0.isSettled }
        if let last = settledPrefix.last {
            releasedThroughID = last.id
            if settledPrefix.contains(where: { !$0.text.isEmpty }) {
                hasReleasedText = true
            }
        }
        trackedText = step.retainedText
        assert(step.desiredText.hasSuffix(step.retainedText))
    }

    /// The tracked text is no longer where we left it: the user moved the cursor or
    /// the host changed the field. Release everything known so far without touching
    /// the document (it may now be anywhere), and carry on with later phrases at
    /// wherever the cursor is.
    mutating func abandonTracked(snapshot: VoiceSessionSnapshot, contextBefore: String?) {
        if let maxID = snapshot.segments.map(\.id).max() {
            releasedThroughID = max(releasedThroughID, maxID)
        }
        trackedText = ""
        hasReleasedText = false
        leadingSeparator = Self.separator(after: contextBefore ?? "")
    }

    private func compose(_ segments: [VoiceSegment]) -> String {
        Self.join(segments, prefix: hasReleasedText ? " " : leadingSeparator)
    }

    private static func join(_ segments: [VoiceSegment], prefix: String) -> String {
        let texts = segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !texts.isEmpty else { return "" }
        return prefix + texts.joined(separator: " ")
    }

    /// A space when the cursor follows a word; nothing at the start of the field or
    /// after whitespace.
    static func separator(after context: String) -> String {
        guard let last = context.last else { return "" }
        return last.isWhitespace || last.isNewline ? "" : " "
    }
}

/// Applies reconciler steps to a live document, verifying before every edit that
/// the tracked text is still immediately before the cursor.
@MainActor
struct VoiceDraftWriter {
    enum Outcome: Equatable {
        case applied
        /// The tracked text was not at the cursor. Nothing was edited.
        case lostTrack
    }

    func apply(_ step: VoiceDraftReconciler.Step, in document: TextDocumentEditing) -> Outcome {
        let context = document.contextBeforeInput ?? ""
        let current = step.currentText
        if !current.isEmpty, !context.hasSuffix(current) {
            return .lostTrack
        }
        let desired = step.desiredText
        guard desired != current else { return .applied }

        // Append-only fast path: the draft grew (the common case while speaking).
        if desired.unicodeScalars.starts(with: current.unicodeScalars) {
            let tail = String(desired.unicodeScalars.dropFirst(current.unicodeScalars.count))
            if !tail.isEmpty { document.insertText(tail) }
            return .applied
        }

        // Rewrite the changed suffix, deleting against the live document by scalar
        // count (the host decides how much one deleteBackward removes), exactly as
        // TextCompositionController does for typed words.
        // The shared prefix is counted in Characters so the delete stops on a
        // grapheme boundary and never splits a conjunct.
        var keptCharacters = 0
        for (old, new) in zip(current, desired) {
            guard old == new else { break }
            keptCharacters += 1
        }
        let keptScalars = current.prefix(keptCharacters).unicodeScalars.count
        let removeScalars = current.unicodeScalars.count - keptScalars
        let targetScalars = context.unicodeScalars.count - removeScalars
        var budget = removeScalars + 8
        while budget > 0, (document.contextBeforeInput?.unicodeScalars.count ?? 0) > targetScalars {
            document.deleteBackward()
            budget -= 1
        }
        let insertion = String(desired.dropFirst(keptCharacters))
        if !insertion.isEmpty { document.insertText(insertion) }
        return .applied
    }
}
