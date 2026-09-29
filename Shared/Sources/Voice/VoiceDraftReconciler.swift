import Foundation

/// Turns the app's transcript snapshots into document edits, keyboard side.
///
/// The document holds, right before the cursor, the dictation's committed text
/// (already appended, never touched again) followed by a small tentative tail
/// (usually the last word, which the recognizer may still revise). Each update
/// replaces only that tail with whatever became committed plus the new tail. So
/// text is deleted only within the tail, a word or two at most, and committed text
/// can never be lost to a host that answers late or shows only part of the field.
///
/// This type is pure: it decides what the tail should read. `VoiceDraftWriter`
/// applies that to a live document.
struct VoiceDraftReconciler: Equatable, Codable {
    struct Step: Equatable {
        /// The tentative tail as it reads in the document now.
        let currentText: String
        /// What should replace it: newly committed text, then the new tail.
        let desiredText: String
        /// The tentative part of `desiredText` (its suffix) that stays tracked.
        let retainedText: String
        /// Committed characters (of the rendered dictation) after this step.
        let committedAfter: Int
        /// The dictation is complete and fully in the document after this step.
        let completesDictation: Bool
    }

    private(set) var dictationID: String?
    /// Separator before the first word, decided at `begin` from what precedes the
    /// cursor.
    private(set) var leadingSeparator = ""
    /// Characters of the rendered dictation (separator + text) already committed
    /// into the document.
    private(set) var committed = 0
    /// The tentative text currently in the document after the committed text.
    private(set) var trackedText = ""

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
        let transcript = snapshot.transcript
        let rendered = render(transcript.text)
        let stable = transcript.stableLength > 0 ? render(String(transcript.stableText)).count : 0
        // Committed text only grows; a snapshot that claims less is out of date.
        let committedAfter = max(stable, committed)
        let desired = String(rendered.dropFirst(committed))
        let retained = String(rendered.dropFirst(committedAfter))
        let completes = transcript.isFinal && (snapshot.phase == .ready || snapshot.phase == .idle)
        if desired == trackedText, committedAfter == committed, !completes {
            return nil
        }
        return Step(
            currentText: trackedText,
            desiredText: desired,
            retainedText: retained,
            committedAfter: committedAfter,
            completesDictation: completes
        )
    }

    /// Record that `step` was applied to the document.
    mutating func didApply(_ step: Step) {
        committed = step.committedAfter
        trackedText = step.retainedText
        assert(step.desiredText.hasSuffix(step.retainedText))
    }

    /// The tail could not be verified for a while: the document no longer shows it
    /// before the cursor, which almost always means the cursor moved or the host
    /// changed the field. Nothing is deleted. The newly committed text is written at
    /// the cursor, wherever it now is (dropping it would lose speech), and tracking
    /// restarts from there. Returns what to insert.
    mutating func fallbackInsertion(for step: Step) -> String {
        let newlyCommitted = String(step.desiredText.prefix(step.committedAfter - committed))
        committed = step.committedAfter
        trackedText = ""
        return newlyCommitted
    }

    private func render(_ text: String) -> String {
        text.isEmpty ? "" : leadingSeparator + text
    }

    /// A space when the cursor follows a word; nothing at the start of the field or
    /// after whitespace.
    static func separator(after context: String) -> String {
        guard let last = context.last else { return "" }
        return last.isWhitespace || last.isNewline ? "" : " "
    }
}

/// Applies reconciler steps to a live document.
///
/// Before touching anything it checks that the draft it wrote is still immediately
/// before the cursor, so it can never delete text it does not own. The check uses
/// an anchor (the draft's last characters), not the whole draft: hosts expose only a
/// window of text before the cursor, and a long phrase outgrows it. Matching the
/// whole draft made the keyboard give up mid-dictation ("lost track of draft") while
/// speech kept arriving, which looked like the recognizer skipping words.
@MainActor
struct VoiceDraftWriter {
    enum Outcome: Equatable {
        case applied
        /// The document did not (yet) show our draft at the cursor. Nothing was
        /// edited. Usually a host that has not caught up; the caller retries and
        /// gives up only if it persists.
        case stale
    }

    /// Long enough to be unambiguous, short enough to fit any host's window.
    /// Counted in Unicode scalars: that is what we inserted, and some hosts delete
    /// one scalar per backspace, leaving a half cluster that a Character comparison
    /// cannot see.
    static let anchorScalars = 48

    /// Whether `context` (what the host shows before the cursor) ends with `text`,
    /// judged scalar for scalar on `text`'s last `anchorScalars`. A host window
    /// shorter than that is accepted when it is entirely the end of `text`.
    static func contextEnds(_ context: String, with text: String) -> Bool {
        let anchor = Array(text.unicodeScalars.suffix(anchorScalars))
        guard !anchor.isEmpty else { return true }
        let tail = Array(context.unicodeScalars.suffix(anchor.count))
        if tail == anchor { return true }
        let window = Array(context.unicodeScalars)
        return window.count >= 4 && window.count < anchor.count && anchor.suffix(window.count).elementsEqual(window)
    }

    func apply(_ step: VoiceDraftReconciler.Step, in document: TextDocumentEditing) -> Outcome {
        let context = document.contextBeforeInput ?? ""
        let current = step.currentText
        guard Self.contextEnds(context, with: current) else { return .stale }
        let desired = step.desiredText
        guard desired != current else { return .applied }

        // Append-only fast path: the draft grew (the common case while speaking).
        if desired.unicodeScalars.starts(with: current.unicodeScalars) {
            let tail = String(desired.unicodeScalars.dropFirst(current.unicodeScalars.count))
            if !tail.isEmpty { document.insertText(tail) }
            return .applied
        }

        // Rewrite from the first changed character. The shared prefix is counted in
        // Characters so the edit starts on a grapheme boundary and never splits a
        // conjunct.
        var keptCharacters = 0
        for (old, new) in zip(current, desired) {
            guard old == new else { break }
            keptCharacters += 1
        }
        var remaining = String(current.dropFirst(keptCharacters))
        // Delete only while the document still visibly ends with (what is left of)
        // the text being replaced. How much one deleteBackward removes is up to the
        // host; after each press we re-read what remains rather than count.
        var steps = remaining.unicodeScalars.count + 2
        while !remaining.isEmpty, steps > 0 {
            guard Self.contextEnds(document.contextBeforeInput ?? "", with: remaining) else { break }
            document.deleteBackward()
            steps -= 1
            remaining = Self.remainder(of: remaining, after: document.contextBeforeInput ?? "")
        }
        let insertion = String(desired.dropFirst(keptCharacters))
        if !insertion.isEmpty { document.insertText(insertion) }
        return .applied
    }

    /// The longest proper prefix of `text` (in scalars) that the document still
    /// ends with.
    private static func remainder(of text: String, after context: String) -> String {
        var scalars = Array(text.unicodeScalars)
        while !scalars.isEmpty {
            scalars.removeLast()
            var candidate = String.UnicodeScalarView()
            candidate.append(contentsOf: scalars)
            let string = String(candidate)
            if scalars.isEmpty || contextEnds(context, with: string) { return string }
        }
        return ""
    }
}
