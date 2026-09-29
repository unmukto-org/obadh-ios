import Foundation

/// Decides which transcript of a finished phrase stands: the streaming draft or the
/// second-pass (refiner) reading.
///
/// The refiner is more accurate word for word, but CTC models occasionally drop a
/// whole stretch of a phrase (measured: IndicConformer lost opening clauses the
/// streaming model had). A refined reading much shorter than the draft is therefore
/// treated as a deletion and the draft is kept. On the benchmark this rule took
/// Bangladeshi-speech CER from 11.3 (refiner alone) and 10.3 (streaming alone) to
/// 9.8, at a cost of 0.3 on Indian-accent FLEURS.
enum VoicePhraseArbiter {
    static let defaultGuardRatio = 0.85

    static func choose(streaming: String, refined: String?, guardRatio: Double = defaultGuardRatio) -> String {
        let draft = normalize(streaming)
        guard let refined else { return draft }
        let reading = normalize(refined)
        if reading.isEmpty { return draft }
        if draft.isEmpty { return reading }
        let draftLength = Double(draft.unicodeScalars.count)
        let readingLength = Double(reading.unicodeScalars.count)
        return readingLength >= guardRatio * draftLength ? reading : draft
    }

    /// NFC, single spaces, no leading or trailing whitespace.
    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
