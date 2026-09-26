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
    /// Ordinary opt-in correction; exact loanwords have a separate default below.
    private(set) var autocorrectTarget: String?
    private(set) var exactLoanwordTarget: String?
    private var correctionsResolved = false

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

    /// Canonical input shared by preview and asynchronous correction queries.
    /// Keep romanBuffer unchanged so qq precedence and deletion are reversible.
    var engineInput: String {
        Self.engineInput(for: romanBuffer)
    }

    static func engineInput(for input: String) -> String {
        let keys = Array(input)
        var result = ""
        var index = 0
        while index < keys.count {
            // Only t/T + a single lowercase q is the iOS khanda-ta shortcut.
            // A following qq belongs to the engine's chandrabindu rule instead:
            // tq → t``, but tqq stays tqq. Other Q spellings remain unchanged.
            if (keys[index] == "t" || keys[index] == "T"),
               index + 1 < keys.count, keys[index + 1] == "q",
               index + 2 == keys.count || keys[index + 2] != "q" {
                result.append(keys[index])
                result.append("``")
                index += 2
            } else {
                result.append(keys[index])
                index += 1
            }
        }
        return result
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
        guard let exactLoanwordTarget else { return compositionSuggestions }
        return Self.mergeSuggestions(
            primary: [KeyboardSuggestion(text: exactLoanwordTarget, source: .autocorrect)]
                + Array(compositionSuggestions.prefix(1)),
            fallback: compositionSuggestions,
            limit: max(2, compositionSuggestionLimit)
        )
    }

    /// Exact loanwords always offer the literal as a quoted second choice, even
    /// when that literal also happens to be a dictionary word.
    func quotedLiteral(isOutOfVocabulary: Bool) -> String? {
        exactLoanwordTarget != nil || isOutOfVocabulary ? preview : nil
    }

    /// What committing right now (space, return, punctuation) should insert: the
    /// auto-insert correction when one is active, otherwise the shown deterministic word.
    var commitText: String {
        exactLoanwordTarget ?? autocorrectTarget ?? preview
    }

    /// Exact English loanwords are default transliterations regardless of the
    /// correction toggle, learned-word protection, edit cost or frequency ratio.
    /// The engine owns case folding and ranking; fuzzy matches are excluded.
    /// All other corrections retain the opt-in AutoInsertGate policy.
    func resolveAutocorrectTarget(
        autoInsertEnabled: Bool,
        baselineFrequency: UInt64,
        detailedCorrections: [DetailedCorrection],
        isProtectedWord: (String) -> Bool
    ) {
        autocorrectTarget = nil
        exactLoanwordTarget = nil
        correctionsResolved = true
        guard hasActiveInput else { return }
        guard let shown = compositionSuggestions.first, shown.source == .deterministic else { return }
        if let loanword = detailedCorrections.first(where: {
            $0.source == DetailedCorrection.Source.englishLoanwordExact
                && $0.romanRepairCost == 0 && !$0.text.isEmpty
        }) {
            if loanword.text != shown.text { exactLoanwordTarget = loanword.text }
            return
        }
        guard autoInsertEnabled else { return }
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
        // Preserve the actual keys. Platform shortcuts are normalized only at
        // the engine boundary; editing units are handled in deleteBackward.
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
            // This also applies after t: both tq and tqq delete back to t.
            removeCount = 2
        }
        romanBuffer.removeLast(removeCount)
        refreshDeterministic()
        return true
    }

    func commitActiveInput() -> String? {
        guard hasActiveInput else { return nil }
        // A rapid delimiter can beat the asynchronous ribbon query. Resolve once
        // at that boundary so exact loanwords do not depend on typing speed. This
        // never puts a full correction query on each letter's preview path.
        if !correctionsResolved {
            resolveAutocorrectTarget(
                autoInsertEnabled: false,
                baselineFrequency: 0,
                detailedCorrections: engine.detailedCorrections(for: engineInput, limit: autocorrectFetchLimit),
                isProtectedWord: { _ in false }
            )
        }
        let committed = commitText
        romanBuffer.removeAll(keepingCapacity: true)
        compositionSuggestions.removeAll(keepingCapacity: true)
        emojiSuggestions.removeAll(keepingCapacity: true)
        autocorrectTarget = nil
        exactLoanwordTarget = nil
        correctionsResolved = false
        generation &+= 1
        return committed
    }

    func clear() {
        romanBuffer.removeAll(keepingCapacity: true)
        compositionSuggestions.removeAll(keepingCapacity: true)
        emojiSuggestions.removeAll(keepingCapacity: true)
        autocorrectTarget = nil
        exactLoanwordTarget = nil
        correctionsResolved = false
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
        exactLoanwordTarget = nil
        correctionsResolved = false
        guard hasActiveInput else {
            compositionSuggestions.removeAll(keepingCapacity: true)
            emojiSuggestions.removeAll(keepingCapacity: true)
            return
        }

        let deterministic = engine.transliterate(engineInput)
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
