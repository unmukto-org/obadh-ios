import Foundation

/// The document-mutating result of a smart-punctuation rule: delete this many
/// characters immediately before the caret, then insert this string.
struct SmartPunctuationResult: Equatable {
    let deleteBefore: Int
    let insertion: String

    static func insert(_ text: String) -> SmartPunctuationResult {
        SmartPunctuationResult(deleteBefore: 0, insertion: text)
    }
}

/// Apple-style smart punctuation, implemented entirely on the iOS layer (the
/// Obadh engine only maps `.`→`।` and `$`→`৳`). Rules mirror the native
/// keyboard's defaults, adapted for Bangla where the sentence terminator is the
/// দাঁড়ি `।` rather than a Latin period.
enum SmartPunctuation {
    static let emDash = "\u{2014}"        // —
    static let ellipsis = "\u{2026}"      // …
    static let dari = "\u{0964}"         // ।
    static let leftDoubleQuote = "\u{201C}"
    static let rightDoubleQuote = "\u{201D}"
    static let leftSingleQuote = "\u{2018}"
    static let rightSingleQuote = "\u{2019}"

    /// Substitution for a literal symbol keystroke, given the text before the
    /// caret. Handles `--`→em dash, `...`→ellipsis, and straight→curly quotes.
    /// Any other symbol is inserted verbatim.
    static func literalSubstitution(for raw: String, contextBefore: String,
                                    smartQuotes: Bool = true, smartDashes: Bool = true,
                                    smartEllipsis: Bool = true) -> SmartPunctuationResult {
        switch raw {
        case "-" where smartDashes && contextBefore.hasSuffix("-") && !contextBefore.hasSuffix(emDash):
            return SmartPunctuationResult(deleteBefore: 1, insertion: emDash)
        case "." where smartEllipsis && endsWithTwoLiteralDots(contextBefore):
            return SmartPunctuationResult(deleteBefore: 2, insertion: ellipsis)
        case "\"" where smartQuotes:
            return .insert(isOpeningContext(contextBefore) ? leftDoubleQuote : rightDoubleQuote)
        case "'" where smartQuotes:
            return .insert(isOpeningContext(contextBefore) ? leftSingleQuote : rightSingleQuote)
        default:
            return .insert(raw)
        }
    }

    /// The Bangla equivalent of iOS's "double-space inserts a period" shortcut:
    /// after a word, a second space becomes `। ` (dari + space). Returns nil
    /// when the shortcut should not fire (caller also gates on recency).
    static func doubleSpaceSubstitution(contextBefore: String, terminator: String = dari) -> SmartPunctuationResult? {
        guard contextBefore.hasSuffix(" ") else { return nil }
        let beforeSpace = contextBefore.dropLast()
        guard let last = beforeSpace.last, isWordCharacter(last) else { return nil }
        return SmartPunctuationResult(deleteBefore: 1, insertion: terminator + " ")
    }

    private static func endsWithTwoLiteralDots(_ context: String) -> Bool {
        let dots = context.reversed().prefix(while: { $0 == "." }).count
        // Fire only on the third dot so "." and ".." pass through unchanged.
        return dots >= 2
    }

    private static func isOpeningContext(_ contextBefore: String) -> Bool {
        guard let last = contextBefore.last else { return true }
        if last.isWhitespace { return true }
        return "([{\u{201C}\u{2018}\u{0964}".contains(last)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
