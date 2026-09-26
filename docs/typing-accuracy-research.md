# Touch and transliteration accuracy investigation

Date: 2026-09-25. Branch: `research/touch-accuracy-baseline`.
Production comparison: Release 112, `a0abe326`. Research started at `df627ea`.
Primary device: iPhone 16 Pro Max, iOS 27.0. Available simulator: iOS 26.5.
The user wants **one-thumb and two-thumb typing weighted equally**, and agreed to a short prompted session.

## Conclusions and current evidence

1. **Verified routing defect:** the production touch surface accepts one touch. An overlapping second thumb is ignored. Controlled UIKit tests reproduced `down(a), down(b), up(a), up(b)` becoming `a`, and the same loss with reversed releases. This is independent of transliteration quality.
2. **Implemented candidate:** retain contacts and serialize their commits in touch-down order. Do not invent early releases. Preserve each contact's own final position and iPad flick origin. Cancel all contacts on dismissal/layout replacement. Preserve the existing spatial resolver for an interpretable comparison.
3. **Measurement is now executable:** native standalone motor-task app, frozen 112 routing control, candidate routing, prompted trials, actual production key views/geometry, local trace export, Unicode-aware scores, paired comparisons, and regression tests. This does not replace the installed keyboard.
4. **Not yet demonstrated:** better human accuracy, faster typing, a learned finger-offset model, or better Bangla decoding. No human trace has been collected in this work yet. Simulator routing tests cannot establish these outcomes.
5. **Best architectural direction:** combine uncertain Roman-key candidates with the existing Bangla transliteration/correction pipeline, while retaining literal input and predictable deliberate key selection. The next model should be chosen from held-out data, not hand-tuned on the simulator.

The earlier system-owned keyboard-height and foreground text-proxy problems remain separate unresolved issues. The standalone app cannot validate those extension behaviors. They must be checked again before a keyboard release.

## What the code actually does

| Layer | Current behavior | Accuracy implication |
| --- | --- | --- |
| UIKit delivery, `KeyboardTouchSurfaceView` in 112 | `isMultipleTouchEnabled = false`; one `activeTouch`; ignores another began event | A second thumb can disappear before the engine sees a character. Verified with failing regressions before editing. |
| Position choice | Resolves current/lift-off `location(in:)`; supports sliding across keys | Users can intentionally retarget before releasing. Switching blindly to touchdown selection changes that interaction. |
| Spatial resolution, `KeyboardTouchResolver` | Chooses a horizontal row band, then vertical key band, with gaps/edges filled | Guarantees coverage, not intent accuracy. Near staggered-row boundaries, plausible diagonal alternatives are discarded. This is a model limitation, not proof a specific tap was wrong. |
| Surface bounds | Starts inside key area; tracked coordinates clamp to edge keys | Preserves low thumb taps. Very large drags can still select an edge command. Needs labeled negative examples before changing cancellation thresholds. |
| Controller | One active highlight/preview and backspace repeater; backspace begins on key-down | Merely enabling multi-touch could reorder deletion, shift, or repeated actions. Must serialize semantic callbacks or redesign ownership. |
| Composer | Receives chosen Roman characters, not coordinates or probabilities | Spatial ambiguity is irrecoverable at this boundary. A new decoder needs an explicit candidate interface. |
| Transliteration | Case-sensitive Roman buffer; multi-letter rules; `qq` shortcut; composition-joining colon | English spelling correction, case folding, and independent character replacement can corrupt intentional Bangla input. |
| Correction | Deterministic preview retained; separate suggestions and strict auto-insert gate | Preserve this separation. A candidate in the ribbon has a much lower failure cost than an unwanted replacement. |
| Existing debug tap command | Calls key handling directly | Useful engine test, but bypasses finger routing and cannot measure finger accuracy. |

### Candidate rollover semantics and limits

Contacts are ordered by their began timestamps. Same-event ties use position for reproducibility; simultaneous physical taps have no recoverable linguistic order. A finished second contact waits for the first to finish/cancel. Finished contacts retain their final positions. Single-contact lift-off selection remains available. Row rebuild/dismissal invalidates the entire queue, including already released contacts waiting behind another finger.

Delegate callbacks remain serial so backspace does not start deleting text before an earlier letter commits. Reentrant cancellation during a commit invalidates queued work. Regression coverage includes chronological and reverse release, same-event batches, retargeting, duplicate ends, per-finger cancellation, layout replacement, dismissal, delete ordering, iPad flicks and the real composer path.

**Tradeoff to measure:** if someone rests a finger on the keyboard, later taps wait behind it; the second finger's preview/feedback is also delayed. This is a conservative first candidate, not a claim of perfect native behavior. Alternatives are committing the earlier printable contact on the next touchdown, or maintaining per-contact feedback with ordered semantic commits. Both require explicit tests for cancellation, modifiers and flicks. Do not silently adopt either to make a throughput graph look better.

## Primary-source research and critical interpretation

Sources were checked on 2026-09-25. Publication dates below describe the work, not a claim that an old paper represents today's shipping implementation.

### Public iOS APIs

- [Apple: isMultipleTouchEnabled](https://developer.apple.com/documentation/uikit/uiview/ismultipletouchenabled). False delivers only the first touch in a multi-touch sequence; true enables delivery of all touches that begin inside the view. This supports the routing diagnosis. It does not supply key ordering, modifier semantics, or a keyboard decoder.
- [Apple: preciseLocation(in:)](https://developer.apple.com/documentation/uikit/uitouch/preciselocation(in:)). Apple explicitly discourages using this coordinate for hit testing. Its name is not evidence that it will improve key selection. Retain `location(in:)` for the production resolver.
- [Apple: majorRadius](https://developer.apple.com/documentation/uikit/uitouch/majorradius). Radius is approximate, with a tolerance. It is neither the intended target nor a reliable thumb identity. It can be collected as an experimental covariate, not used as ground truth.
- [Apple: coalesced touches](https://developer.apple.com/documentation/uikit/uievent/coalescedtouches(for:)). The coalesced sequence includes the delivered touch. Mixing both streams duplicates samples. Collection has a processing cost and is useful only if trajectories improve held-out performance. The first harness records delivered samples; it does not pretend to capture every hardware sample.
- [Apple: predicted touches](https://developer.apple.com/documentation/uikit/minimizing-latency-with-predicted-touches). Predictions are temporary drawing aids, replaced by real data. Do not commit letters from a predicted point.

### Spatial models, posture and adaptation

- [Sivek & Riley, Spatial model personalization in Gboard, 2022](https://arxiv.org/html/2209.11311). Production Android experiments support local adaptation of Gaussian center offsets with pooled key statistics. A particularly useful negative result: improved spatial fit from some data/cluster choices did not improve typing speed or words-modified ratio; full covariance added no significant benefit. Reported user gains were small, and varied with language/model scale. Words-modified ratio is a proxy, not ground-truth error. Their chosen history size and cluster count are not universal constants for Obadh. Start with regularized offsets and separate posture evaluation; do not justify a large neural model or per-key covariance from this paper.
- [Bi & Zhai, Bayesian Touch, UIST 2013](https://research.google/pubs/bayesian-touch-a-statistic-criterion-of-target-selection-with-finger-touch/). Target selection can use likelihood and target size instead of only Euclidean distance. Its target-selection experiments are not evidence that replacing Obadh's resolver with a Gaussian immediately improves Bengali typing. Large command keys also need special treatment to avoid probability mass swallowing letters.
- [Bi et al., FFitts Law, CHI 2013](https://research.google/pubs/ffitts-law-modeling-finger-touch-with-fitts-law/). Finger precision adds constraints beyond classical pointing geometry. Enlarging visible keys is not a complete solution and trades away layout familiarity or screen space.
- [Jiang et al., How We Type, CHI 2020](https://userinterfaces.aalto.fi/how-we-type-mobile/). Eye/finger measurements distinguish typing strategies and correction behavior. Speed, final errors and correction effort should be evaluated together. We will not pool one-thumb and two-thumb results into a single large average that hides a regression.
- [Jokinen et al., Touchscreen typing as optimal supervisory control, CHI 2021](https://userinterfaces.aalto.fi/touchscreen-typing/resources/touchscreen_typing_as_optimal_adaptation.pdf). A behavioral simulator models attention, motor actions and correction. Such simulations are useful for hypotheses; fitting synthetic touches to our candidate distribution cannot establish human improvement.
- [Capacitive touch images and keyboard decoding, 2024](https://arxiv.org/abs/2410.02264). Raw capacitive heatmaps can contain useful information beyond a centroid. This requires sensor data not supplied by the public UIKit touch APIs inspected here. Do not promise a heatmap decoder from `majorRadius` or private APIs.

### Combining spatial uncertainty with language

- [Goodman et al., Language modeling for soft keyboards, IUI 2002](https://www.microsoft.com/en-us/research/publication/language-modeling-for-soft-keyboards-3/). Joint touch and language likelihood is an established approach. Its old hardware and language setting do not give an Obadh effect size.
- [Usability guided key-target resizing](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/paper-final.pdf). Unrestricted probabilistic resizing can make improbable keys hard to select. A guaranteed central anchor preserves deliberate access. The paper's pixel dimensions and language-model tuning are specific to its experiment. Use the predictability constraint, not copied anchor dimensions.
- [Fowler et al., language modeling and personalization, CHI 2015](https://research.google/pubs/effects-of-language-modeling-and-its-personalization-on-touchscreen-typing-performance/). Offline noisy-touch replay provides a controlled comparison of decoders and language models. Large reported gains on English data are not a prediction for our deterministic phonetic scheme or real fingers.
- [Hellsten et al., Transliterated Mobile Keyboard Input via WFSTs, FSMNLP 2017](https://aclanthology.org/W17-4002/). Particularly relevant: it composes touch decoding with Latin-to-target-script mappings under on-device latency/memory constraints. Its reported evaluation includes Hindi/Tamil; Bengali-script support is not a Bengali accuracy benchmark for Obadh. The transferable lesson is to retain alternative Roman paths until target-language scoring can disambiguate them. Do not replace Obadh's defined phonetic rules with another system's transliteration vocabulary.
- [Google's Gboard engineering account, 2017](https://research.google/blog/the-machine-intelligence-behind-gboard/). Explains spatial modeling, beam search, language models and transliteration. It also describes the difficulty of acquiring reliable touch labels. This is an architectural account of that release, not documentation of Apple's keyboard or proof that an LSTM is required here.
- [Salam et al., Bangla phonetic input and foreign words, 2012](https://aclanthology.org/W12-4806/). Highlights the mismatch between foreign-word spelling and phonetic Bengali input. Loanwords and names deserve separate evaluation; they must not be classified as bad finger placement merely because a dictionary prefers another word.
- [Indic gesture typing, COLING 2020](https://aclanthology.org/2020.coling-main.87/). Joint path/transliteration modeling is relevant conceptually. Gesture datasets and reported gesture accuracies cannot be substituted for tap traces or Obadh-compatible Roman/Bangla pairs.

### Recent work and usable data sources

- [Kirov et al., Context-aware transliteration, Computational Linguistics 2024](https://aclanthology.org/2024.cl-2.2/). Full-sentence context improves informal romanization across South Asian languages. These are text-to-text experiments, not touch decoding; models with future sentence context cannot be compared directly with an incremental keyboard using only left context. Large ensembles also need separate latency/memory validation before on-device use.
- [Google's Dakshina dataset](https://github.com/google-research-datasets/dakshina) supplies Bengali native-script text, attested romanizations and sentence pairs. It is a candidate source for an independently reviewed language test set, not a finger-placement dataset. Its informal romanizations may differ from Obadh's explicit key rules. The repository documents spelling/validation limitations and licenses the dataset CC BY-SA 4.0; preserve provenance and attribution if used. No corpus was imported into the app during this investigation.
- [Bangla LLM transliteration-perturbation study, BLP 2025](https://aclanthology.org/2025.banglalp-1.27/) examines mixed-script robustness. It does not evaluate touch targeting. It supports including mixed-script negative cases, not replacing the keyboard with an LLM.
- [Tap&Say, CHI 2025](https://doi.org/10.1145/3706598.3713376) combines tapping an existing text error with spoken correction. Its reported reductions in correction effort apply to that multimodal editing task, not silent tap-to-type selection. Excluded as a direct candidate for this work.

### Measuring success without fooling ourselves

- [MacKenzie & Soukoreff, CHI 2001](https://www.yorku.ca/mack/CHI01a.htm). Minimum-string-distance errors describe the final text; input effort is needed to expose corrections. A perfect final sentence with many deletions is not an error-free typing experience. Backspace count alone is not the formal corrected-error rate.
- [Sarcar, Arif & Mazalek, Metrics for Bengali Text Entry Research, CHI 2015 workshop](https://theiilab.com/pub/Sarcar_CHI2015c.pdf). Roman input actions, Bangla constituents and rendered clusters differ. Conjuncts and deletion behavior complicate direct comparisons. Their corpus-derived word-length constant should not silently become a universal Bengali WPM conversion. We expose unit definitions and score Roman input separately from Bangla output.

## Proposed decoder, after the first real traces

This is a design proposal, **not enabled production code**.

1. Keep the visible layout stable. Capture actual frames in points for each geometry, including orientation, presentation and display settings.
2. Produce nearby Roman candidates from the touch, initially using an unpersonalized two-dimensional distribution. Compare touchdown, lift-off and robust trajectory summaries offline. Preserve explicit slide-to-retarget behavior.
3. Fit modest, regularized center offsets from independently labeled training sessions. Pool sparse keys; shrink toward zero; cap displacement; require minimum support. Keep left-thumb, right-thumb and two-thumb conditions distinguishable. Use a cold-start fallback. Do not infer handedness just from the left/right half of the keyboard.
4. Keep command keys outside language-driven expansion. Preserve a deliberate central anchor for each letter. A model must never invent Return, delete, shift, keyboard-switch or emoji actions.
5. Carry a bounded set of Roman alternatives through the existing case-sensitive transliterator. Deduplicate identical Bangla outputs, retaining the literal path. Score spatial evidence plus Bangla word/context evidence, with an explicit unknown-word path.
6. Initially show spatially informed alternatives as suggestions. Automatic replacement requires a separate calibrated decision threshold and evidence that harmful replacements have not increased. Preserve the current strict gate and explicit user corrections.
7. Measure runtime on the real device, including suggestion contention. Bound beam width, memory and queue work; cancel obsolete asynchronous results. A slow decoder can worsen typing despite higher offline top-1 accuracy.
8. Personalization must learn from confirmed corrections or carefully aligned prompted traces. Learning the decoder's own guesses as labels creates a feedback loop. Never train on ambiguous Roman-to-Bangla alignments as if they were certain.

We should compare incremental variants: current geometry → rollover only → 2D candidates → regularized offsets → transliteration-aware reranking. Change one major factor per comparison so a win or regression remains explainable.

## Evaluation contract

### Three separate datasets

**A. Routing regression traces:** controlled events with known intent, including overlap, cancellations, layout changes, drift, iPad flicks and commands. These prove event-handling properties. They are not a human accuracy percentage.

**B. Real motor traces:** short prompted Roman phrases, real fingers, matched geometry, both postures. The native lab below is the first pilot. Prompt text alone does not label every finger sample: errors, insertions and corrections require alignment, and ambiguous alignments must be excluded from spatial fitting.

**C. End-to-end Bangla tasks:** independently reviewed Bangla prompts plus accepted Roman alternatives, using the real extension. Include everyday words, rare names, English loanwords, mixed script, punctuation, numbers, intentional case, `qq`, colon, conjuncts and out-of-vocabulary words. Score the intended Bangla text, not merely agreement with the current engine. This dataset and extension trial recorder are still pending.

Keep synthetic and human data visibly separate. No synthetic data in a human headline metric. Split training/tuning/test by session and participant where possible, not randomly by neighboring taps. A personal model can train on one session and test on a later session; a global model needs held-out people. Keep the final evaluation prompts out of tuning. Record engine/model hashes and settings for C.

### Metrics

| Measure | Definition / purpose |
| --- | --- |
| Lost, duplicate, reordered key tokens | Exact expected action sequence in routing tests; isolates delivery from language. |
| Roman CER | Case-sensitive Levenshtein distance / expected Roman length. Can exceed 100% with many insertions. |
| MSD error | Edit distance / maximum(reference length, entered length); not the same denominator as CER. |
| Bangla error | NFC scalar CER **and** grapheme-cluster CER, word error, exact phrase. Never strip joiners or phonemic distinctions to improve a score. Pending end-to-end recorder. |
| Correction burden | Backspaces per 100 reference units, suggestion selections and replacement reversals. Do not call raw backspaces “corrected error rate.” |
| Speed | Explicit units: graphemes/minute in the motor lab; words/minute and separately labeled conventional WPM for Bangla tasks. Include correction time. |
| Harmful corrections | Correct literal/name changed to an unwanted word, with reviewed labels. A key release gate. |
| Latency | Touch timestamp → semantic commit and visible response separately, p50/p95/p99; plus queued-contact waiting. CPU time is not display latency. Lab exports touch/commit timestamps, but has no presentation-latency measurement. |
| Predictability | Every letter center remains selectable; command actions are never inferred by a language model; accessibility activation remains functional. |

### Acceptance decisions, set before fitting

- Routing traces: zero lost/duplicate/reordered committed actions where intent is specified; cancelled gestures never insert; command/flick/lifecycle suites pass.
- Pilot: report paired deltas for each posture and prompt. Eight trials from one person are a usability pilot, not a statistically established general improvement.
- Model experiment: predeclare sample count and practical margins after estimating variability in the pilot. Use participant/session-clustered paired intervals, not millions of correlated taps as independent evidence. Freeze the test set before tuning.
- Require an error/correction improvement with no meaningful speed regression **in either posture**. Weight postures equally in any aggregate. Do not average away a one-thumb regression with more two-thumb trials.
- Require no new incorrect command activation or harmful-name correction in the protected set. Keep candidate fallback available until physical-device validation passes.
- No production enablement of learned offsets or joint decoding solely from improved likelihood, attractive hit maps, or synthetic scores.

## Native pilot and reproducibility

`ObadhAccuracyLab` has its own bundle identifier, ending `.accuracylab`, and does not embed/replace the Obadh keyboard. It runs eight prompted Roman rounds: two phrases × two postures × two routing variants. Variant and posture order are randomized, with variant order reversed for the other posture. This is partial counterbalancing; repeated prompts and practice effects remain limitations.

The baseline file is the Release 112 touch surface copied from `a0abe326`, with only class/protocol names and subclassability changed. Both arms use the same current key views, geometry and resolver. This isolates routing; it is **not a complete reproduction of Release 112's host/editor, feedback, correction engine or backspace-repeat behavior**. The lab uses one deletion per completed delete tap. It has no prediction ribbon and no engine correction. It does not establish extension performance on iOS 27.

Only touches delivered to the study surface are recorded. UIKit may suppress overlapping baseline contacts before this layer; missing contacts are not magically recovered in its trace. The candidate's overlapping traces are useful for offline replay, but the baseline arm alone cannot estimate all physical touches. Do not interpret fewer delivered baseline events as lower effort.

Each completed trial saves local JSON: study/source identity and human/automated provenance, OS/device, randomized order, reference/entered text, explicit variant/posture, actual key frames, contact IDs, delivered touch phases/coordinates/radius/timestamps, semantic commits and backspaces. Timing begins at the first delivered touchdown and ends at the last release/cancellation, excluding the Next-button delay. Interruptions and geometry changes invalidate a trial. Export is a user action through the share sheet. No network transport or everyday keyboard logging is added.

The first session is a pilot and must not be reused both to tune a model and to claim held-out improvement. Use the same thumb throughout one-thumb rounds; record left/right and device grip in session notes. The current small phrase set does not cover the full alphabet or case-sensitive rules. Use a separate expanded, frequency-balanced calibration set before fitting offsets.

### Commands

```sh
swift test
swift run typing-accuracy-report /path/to/exported-session.json
xcodegen generate
xcodebuild test -project Obadh.xcodeproj -scheme ObadhKeyboardLifecycleTests \
  -destination 'platform=iOS Simulator,id=A20ED865-B5D0-499D-A348-78E11B2427BA' \
  -derivedDataPath build/TouchAccuracyTests -parallel-testing-enabled NO \
  -collect-test-diagnostics never -jobs 2 CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Obadh.xcodeproj -scheme ObadhAccuracyLab \
  -destination 'platform=iOS Simulator,id=A20ED865-B5D0-499D-A348-78E11B2427BA' \
  -derivedDataPath build/TouchAccuracyLab -parallel-testing-enabled NO \
  -collect-test-diagnostics never -jobs 2 CODE_SIGNING_ALLOWED=NO
```

Use `scripts/build-accuracy-lab.sh` for a Release device artifact with a source fingerprint. Installation is separate, and the installed production keyboard remains Release 112.

### Evidence log

- Before fix: all three initial overlap/delivery regressions failed; both two-key traces yielded only `a`. `/tmp/obadh-touch-baseline.log`.
- After fix: those three regressions passed. `/tmp/obadh-touch-candidate.log`.
- Expanded UIKit suite and actual-composer integration: see final verification below / `/tmp/obadh-touch-full-tests.log`.
- Core and measurement tests: `/tmp/obadh-accuracy-core-tests.log`.
- Native app UI/export smoke test: `/tmp/obadh-accuracy-lab-ui.log`.

No percentage improvement in human typing is claimed by any of these test counts.

## Final verification for this change

- `swift test`: **142 tests passed**, including six metric/normalization/report checks.
- UIKit lifecycle suite: **32 tests passed**, including 13 touch accuracy tests and the real-composer overlap path.
- Native lab UI test: **1 passed**; actual coordinate taps typed `ab`, Delete produced `a`, Next saved a trial.
- Export was read from the simulator app container: automated provenance, actual key frames, delivered touch samples, and three commits were present. The command-line report successfully read it. This intentionally incomplete smoke phrase is not a typing-performance result.
- Release device build succeeded and strict code-signature verification passed. Its Info.plist contains the source fingerprint; this was checked explicitly after discovering that an arbitrary generated Info.plist build-setting key was not emitted.
- Frozen baseline was mechanically compared with `git show a0abe326:Shared/Sources/Keyboard/KeyboardTouchSurfaceView.swift`; only the documented naming/subclassability substitutions differ.
- A candidate-only transition regression was also reproduced before fixing: overlapping Emoji + B initially left `b` in the hidden composer. Immediate cancellation on emoji/switch/dismiss now prevents queued contacts surviving those actions. `/tmp/obadh-touch-emoji-baseline.log` preserves the failing case.
- The separate Release study app was installed on the iPhone 16 Pro Max as `org.unmukto.obadh.accuracylab`. Installed production Release 112 was not rebuilt or replaced by these experiments.

### Next evidence needed

Run the eight-round physical-device pilot, note which thumb/hand is used for one-thumb rounds, and export its JSON. Inspect losses, corrections, speed, and queue delays per posture before selecting the next candidate. Expand the prompt set and collect a separate calibration/evaluation session before learning key offsets. The complete Bangla-output benchmark and any transliteration-aware decoder remain subsequent work; this report does not mark them solved.

Device launch was attempted after installation, but CoreDevice reported the phone locked. Open **Obadh Accuracy** after unlocking; installation itself succeeded. No physical-device typing result is recorded yet.
