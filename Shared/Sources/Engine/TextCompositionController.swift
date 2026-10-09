import Foundation

@MainActor
protocol TextDocumentEditing {
    var contextBeforeInput: String? { get }

    func insertText(_ text: String)
    func deleteBackward()
}

/// Renders the word being composed as ordinary document text and rewrites it in place
/// as the user types, rather than holding it as marked text.
///
/// Marked text is an IME composition that binds the insertion point to itself until
/// confirmed, so the cursor cannot leave a half-typed word — and freeing it depends on
/// each host delivering selection callbacks, which many don't. Inserting real text and
/// re-deriving it sidesteps all of that: the word is always committed text, the cursor
/// moves freely, switching keyboards keeps the word for nothing, and there is no marked
/// region to strand.
///
/// The only state is `composedText`: the exact string we last inserted for the current
/// word. Every rewrite verifies that string is still at the cursor before touching it,
/// so a cursor move or a host edit we didn't observe can never make us delete text we
/// don't own — at worst we start a fresh word.
@MainActor
final class TextCompositionController {
    private(set) var composedText = ""

    var hasActiveComposition: Bool {
        !composedText.isEmpty
    }

    /// Forget the current word without touching the document. The text stays as-is (it
    /// is already real), so this is what to call when the cursor moves, the keyboard is
    /// switched away, or the host rewrites the field.
    func resetHostState() {
        composedText = ""
    }

    /// Make the current word read as `text`, replacing whatever we last inserted for it.
    ///
    /// Deletes only the changed suffix (keeping the common prefix) to minimise edits and
    /// visible flicker. If our tracked word is no longer at the cursor — the user moved,
    /// or the host changed the text — we abandon it untouched and insert `text` fresh.
    func setComposition(_ text: String, in document: TextDocumentEditing) {
        let current = composedText
        let context = document.contextBeforeInput ?? ""

        if !current.isEmpty, !context.hasSuffix(current) {
            // Our word is not where we left it. Don't delete whatever is now at the
            // cursor; treat this as a brand-new composition.
            composedText = ""
            if !text.isEmpty {
                document.insertText(text)
            }
            composedText = text
            return
        }

        // Fast path: the new rendering only appends scalars to the old one — a vowel sign
        // or nasal joining the current cluster, the common case while typing. Insert just
        // the tail; it re-clusters on screen with no delete, so there is no flicker.
        // (A grapheme prefix would miss this: "বা" is not a Character-prefix of "বাং".)
        if text.unicodeScalars.starts(with: current.unicodeScalars) {
            let tail = String(text.unicodeScalars.dropFirst(current.unicodeScalars.count))
            if !tail.isEmpty {
                document.insertText(tail)
            }
            composedText = text
            return
        }

        // General case (a reshape, a shortening, or a correction replacing the word):
        // remove the changed suffix, then insert the new one. The suffix is deleted
        // against the LIVE document, not by counting our own grapheme clusters —
        // deleteBackward's unit is the host's, and a Bangla conjunct may be one press or
        // several. Counting graphemes and trusting the count is what left half-replaced
        // words like "বানহবাংলা". Scalars decrease monotonically however the host chunks
        // a delete, so we delete until the document's scalar length reaches where the
        // shared (grapheme-aligned) prefix ends.
        let keep = current.commonPrefix(with: text)
        let removeScalars = current.unicodeScalars.count - keep.unicodeScalars.count
        let targetScalars = context.unicodeScalars.count - removeScalars
        var budget = removeScalars + 8   // guard against a host that never shrinks
        while budget > 0, (document.contextBeforeInput?.unicodeScalars.count ?? 0) > targetScalars {
            document.deleteBackward()
            budget -= 1
        }
        let insertion = String(text[keep.endIndex...])
        if !insertion.isEmpty {
            document.insertText(insertion)
        }
        composedText = text
    }

    /// Finalize the current word, optionally replacing it with `finalText` (an
    /// autocorrect pick differing from what is shown), then append `trailingText` (a
    /// space, a dari, a newline). The word is already real text, so with no replacement
    /// and no trailing text this is just dropping our tracking.
    @discardableResult
    func commit(finalText: String, trailingText: String = "", in document: TextDocumentEditing) -> Bool {
        if !finalText.isEmpty, finalText != composedText {
            setComposition(finalText, in: document)
        }
        if !trailingText.isEmpty {
            document.insertText(trailingText)
        }
        let didCommit = hasActiveComposition || !trailingText.isEmpty
        composedText = ""
        return didCommit
    }

    /// Replace the current word with an accepted suggestion, keeping it as plain text
    /// with no trailing space (the caller decides what follows).
    func commitSuggestion(_ text: String, in document: TextDocumentEditing) {
        guard !text.isEmpty else { return }
        setComposition(text, in: document)
        composedText = ""
    }

    func commitNextWordSuggestion(_ text: String, insertingSpaces: Bool = true, in document: TextDocumentEditing) {
        guard !text.isEmpty else { return }
        if insertingSpaces, let previous = document.contextBeforeInput?.last, !previous.isWhitespace {
            document.insertText(" ")
        }
        document.insertText(text)
        if insertingSpaces { document.insertText(" ") }
    }

    /// Insert a literal space. The space key is explicit user intent: native inserts
    /// a space even directly after another space (the double-space dari shortcut
    /// belongs to the caller, is time-gated, and replaces the first space only when
    /// it fires). The old whitespace guard here silently swallowed the second of two
    /// deliberate spaces mid-text.
    func insertSpace(in document: TextDocumentEditing) {
        document.insertText(" ")
    }

    /// Delete the current word from the document (e.g. word-unit backspace mid-compose).
    func clearComposition(in document: TextDocumentEditing) {
        setComposition("", in: document)
    }

    /// Replace `word` — which must be the text immediately before the cursor — with
    /// `replacement`. Used to re-edit an already-committed word the cursor sits in, once
    /// the caller has moved the cursor to the word's end. Deletes against the live
    /// document (by scalar length) so it's robust to how the host chunks deleteBackward,
    /// the same way setComposition's replacement path is.
    func replaceWordBeforeCursor(_ word: String, with replacement: String, in document: TextDocumentEditing) {
        guard !word.isEmpty else { return }
        let context = document.contextBeforeInput ?? ""
        guard context.hasSuffix(word) else { return }
        let targetScalars = context.unicodeScalars.count - word.unicodeScalars.count
        var budget = word.unicodeScalars.count + 8
        while budget > 0, (document.contextBeforeInput?.unicodeScalars.count ?? 0) > targetScalars {
            document.deleteBackward()
            budget -= 1
        }
        if !replacement.isEmpty {
            document.insertText(replacement)
        }
    }
}
