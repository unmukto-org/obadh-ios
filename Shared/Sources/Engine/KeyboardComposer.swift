import Foundation

struct KeyboardSuggestion: Equatable {
    let text: String
    let source: Source

    enum Source: Equatable {
        case deterministic
        case autocorrect
        case autosuggest
    }
}

final class KeyboardComposer {
    private let engine: BanglaTypingEngine
    private let emojiSuggester: BanglaEmojiSuggesting?
    /// How many candidates to keep for the strip. Settable because it is a property
    /// of the layout, not of the engine: an iPad shows more of them than an iPhone,
    /// and rotating between layout families changes it.
    var compositionSuggestionLimit: Int
    private(set) var romanBuffer = ""
    private var compositionSuggestions: [KeyboardSuggestion] = []
    /// Up to 3 high-confidence emoji for the currently-composed word, shown in the
    /// bar's trailing region (which replaces the 3rd text candidate, native-style)
    /// — kept separate from the text candidates so the top two always survive.
    private var emojiSuggestions: [String] = []
    /// Bumped on every buffer change so stale async autocorrect results (fetched
    /// off the main thread) can be discarded when they arrive out of order.
    private(set) var generation = 0
    /// When the opt-in auto-insert feature is on, the correction that space/return should
    /// commit instead of the shown deterministic word — nil when the shown word stands.
    private(set) var autocorrectTarget: String?

    init(
        engine: BanglaTypingEngine,
        emojiSuggester: BanglaEmojiSuggesting? = nil,
        compositionSuggestionLimit: Int = 3
    ) {
        self.engine = engine
        self.emojiSuggester = emojiSuggester
        self.compositionSuggestionLimit = compositionSuggestionLimit
    }

    var hasActiveInput: Bool {
        !romanBuffer.isEmpty
    }

    /// Number of candidates the caller should request for the async autocorrect
    /// fetch (one extra so the deterministic entry never crowds out corrections).
    var autocorrectFetchLimit: Int {
        compositionSuggestionLimit + 1
    }

    var preview: String {
        compositionSuggestions.first?.text ?? ""
    }

    var activeSuggestions: [KeyboardSuggestion] {
        compositionSuggestions
    }

    /// What committing right now (space, return, punctuation) should insert: the
    /// auto-insert correction when one is active, otherwise the shown deterministic word.
    var commitText: String {
        autocorrectTarget ?? preview
    }

    /// Decide whether space should commit a correction rather than the shown word, for
    /// the opt-in auto-insert feature. Kept as pure logic — the engine's lexicon answer
    /// and the feature flag are passed in — so it is exercised without the bridge.
    ///
    /// Fires only when: the feature is on; the shown word is NOT already a real word (in
    /// the lexicon) and is NOT one the user has established; and a confident correction
    /// that differs from it exists. Otherwise the shown word stands and typing is
    /// unchanged.
    /// The AutoInsertGate decision, applied to the top detailed correction that
    /// differs from what the user sees. Provenance-driven (channel, cost,
    /// frequency, baseline ratio) — see AutoInsertGate for the policy.
    func resolveAutocorrectTarget(
        autoInsertEnabled: Bool,
        baselineFrequency: UInt64,
        detailedCorrections: [DetailedCorrection],
        isProtectedWord: (String) -> Bool
    ) {
        autocorrectTarget = nil
        guard autoInsertEnabled, hasActiveInput else { return }
        guard let shown = compositionSuggestions.first, shown.source == .deterministic else { return }
        guard !isProtectedWord(shown.text) else { return }
        guard let top = detailedCorrections.first(where: { $0.text != shown.text }) else { return }
        guard AutoInsertGate.shouldAutoInsert(
            baselineFrequency: baselineFrequency,
            correction: top,
            isProtected: isProtectedWord(top.text)
        ) else { return }
        // The bar must show what space will insert; only fire when the gated
        // correction is actually offered.
        guard compositionSuggestions.contains(where: { $0.text == top.text }) else { return }
        autocorrectTarget = top.text
    }

    /// Up to 3 emoji for the current word (best first), rendered by the bar in its
    /// trailing region. Empty when there's no confident match.
    var activeEmojis: [String] {
        emojiSuggestions
    }

    static func mergeSuggestions(
        primary: [KeyboardSuggestion],
        fallback: [KeyboardSuggestion],
        limit: Int
    ) -> [KeyboardSuggestion] {
        guard limit > 0 else { return [] }

        var merged: [KeyboardSuggestion] = []
        merged.reserveCapacity(limit)
        var seen = Set<String>()

        for suggestion in primary + fallback {
            guard !suggestion.text.isEmpty, seen.insert(suggestion.text).inserted else {
                continue
            }
            merged.append(suggestion)
            if merged.count == limit {
                break
            }
        }

        return merged
    }

    func append(_ scalar: String) {
        // The engine owns Roman aliases, including qq → chandrabindu. Preserve
        // raw input; editing units are handled separately in deleteBackward.
        romanBuffer.append(scalar)
        refreshDeterministic()
    }

    func deleteBackward() -> Bool {
        guard hasActiveInput else { return false }
        var removeCount = 1
        let trailingQs = romanBuffer.reversed().prefix { $0 == "q" }.count
        if trailingQs > 0, trailingQs.isMultiple(of: 2) {
            // qq is one chandrabindu input unit. An odd trailing q is instead
            // the unpaired fallback letter: qqq → qq, but qqqq → qq.
            removeCount = 2
            if trailingQs == 2 {
                let shorterInput = String(romanBuffer.dropLast())
                // A future tq alias can be a meaningful intermediate in tqq.
                // Only retain it if the engine actually renders khanda ta;
                // the current defensive tq → ৎক fallback does not qualify.
                if engine.transliterate(shorterInput).hasSuffix("\u{09CE}") {
                    removeCount = 1
                }
            }
        }
        romanBuffer.removeLast(removeCount)
        refreshDeterministic()
        return true
    }

    func commitActiveInput() -> String? {
        guard hasActiveInput else { return nil }
        // The auto-insert correction when one is active, otherwise the shown word.
        let committed = commitText
        romanBuffer.removeAll(keepingCapacity: true)
        compositionSuggestions.removeAll(keepingCapacity: true)
        emojiSuggestions.removeAll(keepingCapacity: true)
        autocorrectTarget = nil
        generation &+= 1
        return committed
    }

    func clear() {
        romanBuffer.removeAll(keepingCapacity: true)
        compositionSuggestions.removeAll(keepingCapacity: true)
        emojiSuggestions.removeAll(keepingCapacity: true)
        autocorrectTarget = nil
        generation &+= 1
    }

    /// Fast, synchronous: computes only the deterministic transliteration for the
    /// inline marked-text preview. Autocorrect candidates (the expensive FST
    /// traversal) are merged in later via `mergeAutocorrectCandidates`, keeping
    /// them off the per-keystroke critical path.
    private func refreshDeterministic() {
        generation &+= 1
        // The buffer changed; any correction was for the old text. It's re-resolved
        // once fresh candidates merge.
        autocorrectTarget = nil
        guard hasActiveInput else {
            compositionSuggestions.removeAll(keepingCapacity: true)
            emojiSuggestions.removeAll(keepingCapacity: true)
            return
        }

        let deterministic = engine.transliterate(romanBuffer)
        if deterministic.isEmpty {
            compositionSuggestions.removeAll(keepingCapacity: true)
            emojiSuggestions.removeAll(keepingCapacity: true)
        } else {
            compositionSuggestions = [KeyboardSuggestion(text: deterministic, source: .deterministic)]
            // Exact-match emoji for the composed word — high confidence only, so
            // they appear just as a full known word is completed. Cheap binary
            // search, safe on the keystroke path.
            emojiSuggestions = emojiSuggester?.emojis(for: deterministic) ?? []
        }
    }

    /// Merges asynchronously-fetched autocorrect candidates behind the
    /// deterministic preview. Ignored if the buffer changed since the fetch was
    /// requested (generation mismatch).
    func mergeAutocorrectCandidates(_ candidates: [String], generation: Int) {
        guard generation == self.generation, hasActiveInput else { return }

        var merged: [KeyboardSuggestion] = []
        merged.reserveCapacity(compositionSuggestionLimit)
        var seen = Set<String>()

        if let deterministic = compositionSuggestions.first, deterministic.source == .deterministic {
            merged.append(deterministic)
            seen.insert(deterministic.text)
        }
        for text in candidates {
            guard !text.isEmpty, seen.insert(text).inserted else { continue }
            merged.append(KeyboardSuggestion(text: text, source: .autocorrect))
            if merged.count == compositionSuggestionLimit {
                break
            }
        }

        if !merged.isEmpty {
            compositionSuggestions = merged
        }
    }
}
