import Foundation

/// Host hints, expressed without UIKit so layout and typing decisions share one
/// contract. Platform adapters translate their input-field metadata into this value.
struct KeyboardFieldTraits: Equatable {
    enum Kind: CaseIterable {
        case text, ascii, numbersAndPunctuation, email, url, webSearch, social
        case numberPad, decimalPad, phonePad, namePhonePad
    }

    enum Content {
        case ordinary, email, url, identifier, personName, privateText
    }

    enum Preference { case unspecified, disabled, enabled }
    enum Capitalization { case none, words, sentences, allCharacters }
    enum Appearance { case automatic, light, dark }

    var kind: Kind = .text
    var content: Content = .ordinary
    var correction: Preference = .unspecified
    var spelling: Preference = .unspecified
    var smartQuotes: Preference = .unspecified
    var smartDashes: Preference = .unspecified
    var smartInsertDelete: Preference = .unspecified
    var capitalization: Capitalization = .none
    var returnAction: KeyboardReturnAction = .default
    var automaticallyEnablesReturn = false
    var appearance: Appearance = .automatic
    var isSecure = false
    var decimalSeparator = "."
}

enum KeyboardReturnAction: CaseIterable {
    case `default`, go, google, join, next, route, search, send, yahoo, done, emergencyCall, `continue`

    /// Display only. Activation always sends a separate newline to the host;
    /// navigation/submission belongs to its text-input implementation.
    var title: String? {
        switch self {
        case .default: nil
        case .go: "Go"
        case .google: "Google"
        case .join: "Join"
        case .next: "Next"
        case .route: "Route"
        case .search: "Search"
        case .send: "Send"
        case .yahoo: "Yahoo"
        case .done: "Done"
        case .emergencyCall: "Emergency Call"
        case .continue: "Continue"
        }
    }

    var isPrimaryAction: Bool { self != .default }
}

struct KeyboardReturnPresentation: Equatable {
    var action: KeyboardReturnAction = .default
    var isEnabled = true
}

struct KeyboardFieldPolicy: Equatable {
    enum Layout: Equatable {
        case standard, email, url, webSearch, social, numberPad, decimalPad, phonePad

        var isNumeric: Bool {
            switch self {
            case .numberPad, .decimalPad, .phonePad: true
            default: false
            }
        }
    }

    let traits: KeyboardFieldTraits
    let layout: Layout
    let usesBanglaComposition: Bool

    init(traits: KeyboardFieldTraits = .init()) {
        self.traits = traits
        // Explicit keyboard types take precedence over supplemental semantic hints.
        // A code may be alphanumeric: its content type alone must not impose a pad.
        switch traits.kind {
        case .numberPad: layout = .numberPad
        case .decimalPad: layout = .decimalPad
        case .phonePad: layout = .phonePad
        case .email: layout = .email
        case .url: layout = .url
        case .webSearch: layout = .webSearch
        case .social: layout = .social
        case .text, .ascii, .numbersAndPunctuation, .namePhonePad:
            switch traits.content {
            case .email: layout = .email
            case .url: layout = .url
            default: layout = .standard
            }
        }
        usesBanglaComposition = !traits.isSecure
            && traits.kind != .ascii
            && !layout.isNumeric
            && layout != .email && layout != .url
            && traits.content != .identifier && traits.content != .privateText
    }

    var initialMode: KeyboardMode {
        traits.kind == .numbersAndPunctuation || layout.isNumeric ? .numbers : .letters
    }

    private var isProse: Bool {
        !traits.isSecure && !layout.isNumeric && layout != .email && layout != .url
            && traits.content != .identifier && traits.content != .privateText
    }

    var allowsSuggestions: Bool { usesBanglaComposition }
    var allowsCorrections: Bool {
        allowsSuggestions && traits.correction != .disabled && traits.content != .personName
    }
    var allowsCursorCorrections: Bool { allowsCorrections && traits.spelling != .disabled }
    var allowsLearning: Bool {
        usesBanglaComposition && traits.content == .ordinary
    }
    var allowsEmoji: Bool { isProse }
    var allowsVoice: Bool { usesBanglaComposition }
    var allowsSmartQuotes: Bool { isProse && traits.smartQuotes != .disabled }
    var allowsSmartDashes: Bool { isProse && traits.smartDashes != .disabled }
    var allowsSmartSpacing: Bool { isProse && traits.smartInsertDelete != .disabled }
    var allowsDoubleSpacePeriod: Bool { isProse && layout != .webSearch }
    var usesASCIISymbols: Bool { !usesBanglaComposition }
    var needsCapitalizationContext: Bool {
        !usesBanglaComposition && isProse
            && (traits.capitalization == .words || traits.capitalization == .sentences)
    }

    func returnIsEnabled(hasText: Bool) -> Bool {
        !traits.automaticallyEnablesReturn || hasText
    }

    /// Bangla has no case; capitalizing its roman keystrokes changes the phonetic
    /// spelling. Apply host capitalization only to literal Latin input.
    func shouldCapitalize(contextBefore: String?) -> Bool {
        guard !usesBanglaComposition, !layout.isNumeric else { return false }
        if traits.capitalization == .allCharacters { return true }
        guard isProse, let contextBefore else { return false }
        switch traits.capitalization {
        case .none: return false
        case .allCharacters: return true
        case .words:
            return contextBefore.last.map { $0.isWhitespace || "([{\"".contains($0) } ?? true
        case .sentences:
            if contextBefore.isEmpty { return true }
            if contextBefore.last?.isNewline == true { return true }
            guard contextBefore.last?.isWhitespace == true else { return false }
            let preceding = contextBefore.trimmingCharacters(in:
                .whitespaces.union(CharacterSet(charactersIn: "\"'”’)]}")))
            return preceding.isEmpty || preceding.last.map { ".!?।\n\r".contains($0) } == true
        }
    }
}
