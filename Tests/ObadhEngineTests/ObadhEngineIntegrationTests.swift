import Foundation
import ObadhBridge
import os
import Testing

/// Resolves the test bundle so the shipped model artifacts (`bn.fst`, the
/// autosuggest n-gram) can be located the same way the keyboard locates them.
private final class BundleToken {}

/// Real-engine integration tests (ABI v2 / engine 0.9.4).
///
/// Unlike the pure-logic unit suite (which runs under SwiftPM and cannot see the
/// xcframework), this target links `ObadhBridge.xcframework` and bundles the real
/// `ObadhModels` artifacts, so it exercises the actual Swift↔C boundary: opaque-
/// handle lifecycle, the count+length-prefixed record-list decoding, snprintf-style
/// sizing, `word_frequency`, and the fingerprint surface. These are the tests that
/// catch a marshalling regression an engine bump could introduce.
///
/// Serialized because the snapshot test mutates the shared personal-overlay handle.
@Suite(.serialized)
struct ObadhEngineIntegrationTests {
    let engine = ObadhBridgeClient.shared
    let configuration: ObadhModelConfiguration

    init() {
        // Idempotent: opens the handles once, then no-ops on later instances.
        configuration = ObadhBridgeClient.shared.configureModels(in: Bundle(for: BundleToken.self))
    }

    // MARK: - Non-word tokens (engine 0.9.1, issue #34)

    /// A token with no Bangla letter must yield ONLY its deterministic baseline.
    /// Before 0.9.1 the edit-distance channel ran on every baseline, so punctuation
    /// and digits fell within edit distance of the shortest, most frequent lexicon
    /// entries and surfaced as "corrections" in the suggestion bar (`,` pulled in
    /// ও/এ/অং). Pinned here because it is user-visible in our candidate strip and a
    /// future engine bump could regress it.
    @Test(arguments: [",", ".", "1", "12", "()", "?", "!"])
    func nonWordTokensOfferNoLexiconCorrections(token: String) {
        let suggestions = engine.compositionSuggestions(for: token, limit: 4)
        #expect(
            suggestions.count <= 1,
            "\(token) offered \(suggestions.count) candidates: \(suggestions)"
        )
    }

    // MARK: - Configuration

    @Test func modelsLoadFromTheBundledArtifacts() {
        #expect(configuration.autocorrectAvailable)
        #expect(configuration.autosuggestAvailable)
    }

    @Test func linkedEngineVersionAndABI() {
        #expect(obadh_abi_version() == 2)
        let count = obadh_engine_version(nil, 0)
        var bytes = [UInt8](repeating: 0, count: count)
        let written = bytes.withUnsafeMutableBufferPointer {
            obadh_engine_version($0.baseAddress, $0.count)
        }
        #expect(written == count)
        #expect(String(bytes: bytes, encoding: .utf8) == "0.9.4")
    }

    /// Check scalars as well as appearance: the reph-ya form must use ZWJ,
    /// while ordinary conjuncts must not acquire either kind of joiner.
    @Test(arguments: [
        ("rYab", "র\u{200D}্যাব"), ("rZab", "র\u{200D}্যাব"),
        ("rZy", "র\u{200D}্যয়"), ("ry", "রয়"),
        ("krY", "ক্র্য"), ("TrYak", "ট্র্যাক"), ("eksTrYak", "এক্সট্র্যাক"),
        ("gN", "গ্ণ"), ("Ngkt", "ঙ্ক্ত"), ("spl", "স্প্ল"),
        ("katla", "কাতলা"), ("patla", "পাতলা"), ("bOtl", "বোতল"),
        ("sot``lOk", "সৎলোক"),
    ])
    func engine094ConjunctAndJoinerOutputs(roman: String, expected: String) {
        let actual = engine.transliterate(roman)
        #expect(actual.unicodeScalars.map(\.value) == expected.unicodeScalars.map(\.value))
    }

    // MARK: - Deterministic transliteration (goldens)

    @Test(arguments: [
        ("ami", "আমি"),
        ("bangla", "বাংলা"),
        ("banhla", "বানহ্লা"),
        ("kan", "কান"),
        ("", ""),
    ])
    func transliterates(roman: String, expected: String) {
        #expect(engine.transliterate(roman) == expected)
    }

    // MARK: - Compose bar (record-list decoding + baseline-first)

    @Test func composeLeadsWithTheDeterministicBaselineAndDecodesMultipleRecords() {
        let baseline = engine.transliterate("banhla")
        let candidates = engine.compositionSuggestions(for: "banhla", limit: 5)
        #expect(candidates.first == baseline)   // the baseline always leads
        #expect(candidates.count >= 2)           // a multi-record list decoded correctly
        #expect(candidates.contains("বাংলা"))    // the correction is offered behind it
        #expect(!candidates.contains(""))        // framing never yields an empty candidate
    }

    /// Baseline-first is a hard invariant of the compose channel, so it must hold
    /// across a sweep of unrelated inputs — a cheap regression net for the record
    /// framing and the ranker wiring.
    @Test(arguments: ["ami", "tumi", "bangla", "banhla", "boi", "kemon", "bhalo", "pani"])
    func composeBaselineFirstInvariantHolds(roman: String) {
        let baseline = engine.transliterate(roman)
        let candidates = engine.compositionSuggestions(for: roman, limit: 5)
        #expect(candidates.first == baseline)
        #expect(!candidates.contains(""))
    }

    // MARK: - Lexicon frequency (the ratio-gate foundation) + membership

    /// `word_frequency` returns the stored count, 0 for a non-entry. Pinned to the
    /// real `bn.fst` — these are the exact numbers a frequency-ratio auto-insert
    /// gate divides (baseline vs correction), so a shift here would move the gate.
    @Test func wordFrequencyReturnsPinnedCounts() {
        #expect(engine.wordFrequency("বাংলা") == 137_381)
        #expect(engine.wordFrequency("মানুস") == 49)     // the rare typo entry the ratio overrides
        #expect(engine.wordFrequency("যযযযযয") == 0)     // absent → 0 sentinel
    }

    @Test func lexiconMembershipDistinguishesRealWordsFromNonsense() {
        #expect(engine.isLexiconWord("বাংলা"))           // wordFrequency > 0
        #expect(!engine.isLexiconWord("যযযযযয"))
    }

    @Test func wordAlternativesForARealWordAreNonEmpty() {
        #expect(!engine.wordAlternatives(for: "বাংলা", limit: 4).isEmpty)
    }

    // MARK: - Personal overlay snapshot round-trip

    /// Commit a learned word, export the overlay, clear it, and import it back —
    /// exercising commit + snapshot export/import across the boundary.
    @Test func personalSnapshotRoundTripsThroughExportAndImport() throws {
        let word = "খটখটানয়" // out-of-vocabulary nonce
        engine.clearPersonalAutosuggest()
        #expect(engine.commitAutosuggestToken(word))

        let snapshot = try #require(engine.exportPersonalAutosuggestSnapshot())
        #expect(!snapshot.isEmpty)

        engine.clearPersonalAutosuggest()
        #expect(engine.importPersonalAutosuggestSnapshot(snapshot))
    }

    // MARK: - Artifact fingerprints (pinned; catch a silent data swap on a bump)

    /// The engine exposes a content hash of each artifact. Pinning it makes an
    /// unintended artifact change on an engine bump fail loudly here instead of
    /// silently altering suggestions. Update deliberately when the bundled `data/`
    /// submodule is revved. (Unchanged 0.8.1 → 0.9.0 — 0.9.0 is an ABI-only reshape.)
    @Test func artifactFingerprintsMatchThePinnedArtifacts() {
        #expect(engine.autocorrectFingerprint() == Self.pinnedAutocorrectFingerprint)
        #expect(engine.autosuggestFingerprint() == Self.pinnedAutosuggestFingerprint)
    }

    static let pinnedAutocorrectFingerprint: UInt64 = 16_395_964_778_339_222_933
    static let pinnedAutosuggestFingerprint: UInt64 = 12_903_309_268_127_864_731

    // MARK: - Detailed corrections + the auto-insert gate (real artifacts)

    @Test func detailedCorrectionsDecodeForKnownInput() {
        let detailed = engine.detailedCorrections(for: "manus", limit: 5)
        #expect(!detailed.isEmpty)
        #expect(detailed.contains { $0.text == "মানুষ" })
    }

    /// The canonical rare-baseline cases the ratio rule exists for: the typed
    /// forms ARE lexicon words (so a non-word gate can never fire), but the
    /// corrections are overwhelmingly more frequent.
    @Test(arguments: [("manus", "মানুষ"), ("bondu", "বন্ধু")])
    func gateFiresForRareLexiconBaselines(roman: String, expected: String) {
        let baseline = engine.transliterate(roman)
        let baselineFrequency = engine.wordFrequency(baseline)
        #expect(baselineFrequency > 0, "the premise: \(baseline) is a (rare) lexicon word")
        let detailed = engine.detailedCorrections(for: roman, limit: 5)
        let top = detailed.first { $0.text != baseline }
        #expect(top?.text == expected)
        if let top {
            #expect(AutoInsertGate.shouldAutoInsert(
                baselineFrequency: baselineFrequency,
                correction: top,
                isProtected: false
            ))
        }
    }

    /// banhla's repair cost is genuinely 2 (validated with the engine team) —
    /// it waits on the engine's Part 2 cost calibration and must not fire.
    @Test func gateHoldsForCostTwoRepair() {
        let baseline = engine.transliterate("banhla")
        let baselineFrequency = engine.wordFrequency(baseline)
        for candidate in engine.detailedCorrections(for: "banhla", limit: 5)
        where candidate.text == "বাংলা" {
            #expect(!AutoInsertGate.shouldAutoInsert(
                baselineFrequency: baselineFrequency,
                correction: candidate,
                isProtected: false
            ))
        }
    }

    /// A common word must never be overridden by any of its own candidates.
    @Test func gateHoldsForCommonBaselines() {
        let baseline = engine.transliterate("amar")
        let baselineFrequency = engine.wordFrequency(baseline)
        #expect(baselineFrequency > 0)
        for candidate in engine.detailedCorrections(for: "amar", limit: 5)
        where candidate.text != baseline {
            #expect(!AutoInsertGate.shouldAutoInsert(
                baselineFrequency: baselineFrequency,
                correction: candidate,
                isProtected: false
            ))
        }
    }

    @Test func gateRespectsProtectedWords() {
        let correction = DetailedCorrection(
            text: "মানুষ",
            source: DetailedCorrection.Source.editDistance,
            editCost: 1,
            romanRepairCost: nil,
            frequency: 1_000_000
        )
        #expect(!AutoInsertGate.shouldAutoInsert(
            baselineFrequency: 0,
            correction: correction,
            isProtected: true
        ))
    }
}
