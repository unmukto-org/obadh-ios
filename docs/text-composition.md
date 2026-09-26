# Text composition and input behavior

The decisions here were mostly forced by how iOS treats custom keyboards.
Several generalize to any platform.

## Composing in the document, not in a marked region

The word being typed is ordinary text in the field, re-derived in place on
each keystroke, not iOS *marked text*. Marked text is the obvious choice and
the wrong one here: it is an IME composition that binds the insertion point to
itself until committed, so the cursor cannot leave a half-typed word, and
freeing it depends on each host app delivering selection callbacks, which many
do not. A transliteration keyboard is not assembling one glyph from phonetic
parts (where marked text earns its keep); it produces words that should
behave like any other text.

So Obadh inserts the Bangla directly and rewrites the current word as letters
arrive: append just the new sign when the rendering grows (no flicker), delete
whole grapheme clusters past the shared prefix when it reshapes. The cursor
moves freely everywhere, mid-text editing is a plain edit, and switching
keyboards mid-word keeps the word. The discipline this demands: track the
exact string that was inserted and confirm it is still at the cursor before
rewriting, so a cursor move we did not observe never deletes text we do not
own.

## Touch routing

iOS *drops* touches over fully-transparent regions of a keyboard extension
before they reach `hitTest`. The gaps between keys and the padding around the
outer keys were dead zones, and no amount of hit-test slop fixes it: the
event never arrives. The fix is a single near-invisible surface (one plain
view at ~0.004 alpha: non-transparent but imperceptible) covering the whole
key area; it catches every touch and resolves it to the nearest key by
midpoint boundaries. The keys themselves are non-interactive.

## The suggestion ribbon

- The deterministic output renders first, then autocorrect candidates. When
  the typed literal is not a lexicon word it renders quoted (the native
  "keep my spelling" affordance), and every shown slot is tappable.
- Accepting a candidate commits it with a trailing space and advances the
  autosuggest session, like native.
- After a word commits, the ribbon can show next-word suggestions from the
  bundled n-gram model, merged with personally learned words.
- The ribbon follows the cursor. Sitting inside an already-committed word
  offers corrections for that word (tap to swap in place, no trailing space);
  sitting at a boundary offers next-word suggestions. The rule is the
  character just before the cursor: a letter means "editing this word", a
  space means "at a boundary".
- Up to three emoji can take over the third slot for the current word.
  Tapping one **replaces** the word: the typed text was the emoji's query.
  See [emoji.md](emoji.md).

## Space, dari, punctuation

- Space commits the deterministic output (or the gated auto-correction; see
  [autocorrect.md](autocorrect.md)). The space key always inserts: two
  deliberate spaces are two spaces, exactly like native.
- Double-space → `। ` (dari + space) is a *quick double-tap* shortcut
  mirroring native's period shortcut: the second space must land within
  0.35 s, only at the end of the text, only after a word character.
- Numerals and punctuation are handled on the iOS layer: the number pad emits
  Bangla numerals ০–৯, `৳` and `।` sit on the punctuation pages, and
  Apple-style smart punctuation applies (`--`→`—`, `...`→`…`, curly quotes).
- The engine interprets `qq` as চন্দ্রবিন্দু, like its `^` marker. iOS preserves
  the original Roman keys, but backspace removes a completed `qq` as one input
  unit: `baqq` → `ba`. An unpaired final `q` is removed separately (`qqq` → `qq`).
- iOS maps `tq` / `Tq` to the engine's existing double-backtick খণ্ড ত signal:
  `sotq` → সৎ, `utqsob` → উৎসব, `bidyutq` → বিদ্যুৎ. A following `qq` takes
  precedence: `tqq` → তঁ. Backspace walks `tqq` → `tq` → `t` (তঁ → ৎ → ত).
  Other Q spellings keep their engine meaning. The composer retains raw keys
  separately from `engineInput`; preview, correction suggestions and detailed
  auto-insert queries all use the same canonical input. The core engine is unchanged.

## Backspace

Holding backspace follows a native-like curve: immediate delete, fast
character repeat, then word and sentence chunks on a sustained hold. Deletion
is planned against grapheme clusters, so a conjunct never half-deletes.

## The globe

The globe switches to the next keyboard. There is no English typing mode;
switch to Apple's English keyboard when needed. Obadh does one thing.
