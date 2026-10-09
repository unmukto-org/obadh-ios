import Foundation

/// One ranked correction from the engine's `suggest_detailed`, with the provenance
/// the auto-insert gate is built on. Mirrors the packed C record exactly.
struct DetailedCorrection: Equatable {
    /// Frozen, append-only source codes from the engine (`FstCandidateSource`).
    /// Unknown codes must be treated as not-auto-replaceable.
    enum Source {
        static let exact: UInt8 = 0
        static let editDistance: UInt8 = 1
        static let diacriticEdit: UInt8 = 2
        static let orthographicVowelLength: UInt8 = 3
        static let prefixCompletion: UInt8 = 4
        static let stemSuffixCompletion: UInt8 = 5
        static let skeletonVowelDrop: UInt8 = 6
        static let consonantConfusion: UInt8 = 7
        static let romanRepairExact: UInt8 = 8
        static let englishLoanwordExact: UInt8 = 9
        static let englishLoanwordFuzzy: UInt8 = 10
        /// Exact aliases use a separate client policy, not word-frequency gates.
        static let emoticonExact: UInt8 = 11
    }

    let text: String
    let source: UInt8
    let editCost: UInt16
    /// nil when the engine reports no roman-side repair (wire value 0xFFFF).
    let romanRepairCost: UInt16?
    /// Lexicon frequency of the candidate word.
    let frequency: UInt64
}

/// The client-owned auto-insert policy on the engine's 0.9.0 primitives
/// (`suggest_detailed` + `word_frequency`), per the settled architecture: the
/// engine ships provenance, the client owns the decision.
///
/// Fires only when every hurdle passes:
///  - the top correction comes from a CONFIDENT channel (typo-shaped fixes:
///    edit, diacritic, vowel-length, consonant-confusion, roman-repair,
///    loanword-exact) — completion/fuzzy channels and unknown codes never fire;
///  - its effective cost (Bangla edit + roman repair) is at most 1 — a genuine
///    slip, not a rewrite (this is why banhla→বাংলা, repair cost 2, waits on the
///    engine's Part 2 cost calibration);
///  - the correction is a real, common-enough word (frequency floor — drops
///    artifacts like ক্ষিতি f34 and দিনন f2);
///  - and the baseline either isn't a lexicon word at all, or is one so much
///    rarer than the correction that the user almost surely meant the common
///    word (the frequency-RATIO rule — what fixes manus→মানুষ and bondu→বন্ধু,
///    whose typed forms are themselves rare lexicon entries).
enum AutoInsertGate {
    /// Channels that repair a typo rather than complete or guess a word.
    static let confidentSources: Set<UInt8> = [
        DetailedCorrection.Source.editDistance,
        DetailedCorrection.Source.diacriticEdit,
        DetailedCorrection.Source.orthographicVowelLength,
        DetailedCorrection.Source.consonantConfusion,
        DetailedCorrection.Source.romanRepairExact,
        DetailedCorrection.Source.englishLoanwordExact,
    ]

    /// Minimum lexicon frequency for a correction to be trusted at all.
    static let correctionFrequencyFloor: UInt64 = 40

    /// A lexicon-word baseline is overridden only when the correction is at
    /// least this many times more frequent. Calibrated against the real
    /// artifacts in the integration tests (pinned there).
    static let rareBaselineRatio = 50.0

    /// Per-channel cost ceilings, calibrated against the real artifacts (the
    /// engine's cost units are channel-specific weighted distances, not grapheme
    /// counts — মানুস→মানুষ reports editCost 3 through consonant-confusion for a
    /// single confusion swap). Repair stays at 1 so banhla→বাংলা (repair 2)
    /// keeps waiting on the engine's Part 2 cost calibration.
    static func maxEditCost(for source: UInt8) -> Int {
        switch source {
        case DetailedCorrection.Source.consonantConfusion:
            return 3
        default:
            return 1
        }
    }

    static func shouldAutoInsert(
        baselineFrequency: UInt64,
        correction: DetailedCorrection,
        isProtected: Bool
    ) -> Bool {
        guard !isProtected else { return false }
        guard confidentSources.contains(correction.source) else { return false }
        guard Int(correction.editCost) <= maxEditCost(for: correction.source) else { return false }
        guard Int(correction.romanRepairCost ?? 0) <= 1 else { return false }
        guard correction.frequency >= correctionFrequencyFloor else { return false }
        if baselineFrequency == 0 {
            return true
        }
        return Double(correction.frequency) >= rareBaselineRatio * Double(baselineFrequency)
    }
}
