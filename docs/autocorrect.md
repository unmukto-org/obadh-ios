# Autocorrect, auto-insert, and learning

The [engine](https://github.com/nsssayom/obadh_engine) supplies *signals*;
this client owns *policy*. That split is deliberate and was negotiated with
the engine project: an earlier engine-side auto-replace gate failed on the
real lexicon twice, and a data-dependent policy the engine's CI cannot test
(it runs without the data artifacts) should not live in the engine. The 0.9.0
ABI redesign removed the engine gate and shipped provenance instead:
`suggest_detailed` (per-candidate channel, costs, frequency) and
`word_frequency` (the baseline signal). The engine README states the result
plainly: whether to silently apply a correction "is a client decision."

## The suggestion flow

The inline composition remains the deterministic transliteration. One background
`detailedCorrections` query supplies both ribbon candidates and their provenance;
stale generations are discarded.

**Exact English loanwords are the exception to literal-first behavior.** The
engine already matches them case-insensitively (source 9, Roman repair cost 0).
The highest-ranked exact match leads the ribbon and commits on Space, Return or
punctuation, even with Auto-Insert Corrections off. The literal is the quoted,
tappable second entry, including when it is a dictionary word. Identical entries
are deduplicated. Exact matches bypass typo costs, frequency thresholds and learned
spelling protection; explicitly tapping the literal still commits that spelling
for this occurrence. Fuzzy loanwords never receive this exception.

Other input retains literal-first ordering, quoting non-dictionary literals.
Keeping a spelling still protects it from ordinary auto-insertion.

If a delimiter arrives before the background result, the composer resolves the
current token once at commit so loanword acceptance does not depend on typing
speed. Letter previews remain synchronous transliteration only. A resolved token
reuses its result. This boundary fallback can wait for the active engine query;
simulator timings are recorded in the changelog, not a device latency guarantee.

## The auto-insert gate

Ordinary typo correction is off by default (Settings → Autocorrect). After the
exact-loanword policy above, when enabled, space commits the top
correction instead of the literal only when **every** hurdle passes
(`AutoInsertGate` in `Shared/Sources/Engine/`):

1. **Confident channel.** The candidate must come from a typo-shaped channel:
   edit-distance, diacritic edit, orthographic vowel-length, consonant
   confusion, roman-repair-exact, or loanword-exact. Completion and fuzzy
   channels never fire; *unknown channel codes never fire* (the codes are
   frozen and append-only, so a future engine can add channels without
   changing this client's behavior).
2. **Per-channel cost ceiling.** The engine's costs are channel-specific
   weighted distances, not grapheme counts: মানুস→মানুষ reports edit cost 3
   through consonant-confusion for a single swap. Ceilings: confusion ≤ 3,
   everything else ≤ 1, roman repair ≤ 1.
3. **Frequency floor** (40): the correction must be a common-enough real word.
4. **Baseline rule.** The typed literal must be a non-word, *or* a rare
   lexicon word that the correction out-frequencies **50×** (the ratio rule).
   The ratio is what fixes `manus`→মানুষ (baseline frequency 49 vs 95,278)
   and `bondu`→বন্ধু, whose typed forms are themselves lexicon entries and so
   are invisible to any non-word gate.
5. **Not user-protected** (a previously kept spelling).

Deliberately held: `banhla`→বাংলা carries roman-repair cost 2: real, but
above the ceiling until the engine's Part 2 cost calibration (ranking +
key-slip costs against a labeled recall@1 set) lands.

Every constant is calibrated by integration tests that run against the real
bundled artifacts with pinned frequencies and fingerprints; see
[testing.md](testing.md). If a threshold needs to move, the tests move with
it or fail loudly.

## Next-word suggestions and personal learning

After a word commits, the ribbon offers next-word candidates from the bundled
n-gram model merged with a personal overlay of learned words. Learning is
engine-side and bounded; the client persists the exported snapshot in the App
Group and validates its fingerprint on load, so a snapshot from a different
artifact generation is dropped rather than imported.
