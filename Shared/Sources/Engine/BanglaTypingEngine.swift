import Foundation

/// The minimal typing surface the composer needs from the engine. Kept as its own
/// protocol (rather than depending on the concrete `ObadhBridgeClient`) so the
/// composer can be unit-tested with a fake, and so this contract can be compiled
/// into an integration-test target alongside the real bridge without dragging in
/// the rest of the keyboard.
protocol BanglaTypingEngine {
    func transliterate(_ input: String) -> String
    func detailedCorrections(for romanInput: String, limit: Int) -> [DetailedCorrection]
    func compositionSuggestions(for romanInput: String, limit: Int) -> [String]
    func autosuggestSuggestions(for context: String, limit: Int) -> [String]
}

// Deterministic-only engines and lightweight fixtures have no loanword defaults.
extension BanglaTypingEngine {
    func detailedCorrections(for romanInput: String, limit: Int) -> [DetailedCorrection] { [] }
}
