# First physical-device typing pilot — 2026-09-25

## Decision

**This session does not demonstrate an accuracy improvement.** Keep the current production installation (Release 112). Retain the ordered-rollover change as a tested routing candidate, but do not promote it as a proven typing improvement or fit production key offsets to these same phrases.

The complete export has eight rounds and 258 delivered contacts. The earlier export contained only six rounds; the replacement has exactly the same first six records plus the final two. The report tool now explicitly reports planned/exported/missing/duplicate trial IDs so an incomplete export cannot quietly look like a complete comparison.

No keyboard behavior was changed during this analysis. Work is on `research/touch-accuracy-pilot-analysis`.

## Dataset and integrity

- Session: `3568675C-1587-4437-BFDF-4B873A15F15B`.
- Complete source SHA-256: `833019118605f69b9955a24a67c64a8b128d0bb83e4133ec5d32c60897d1987f`.
- Study source fingerprint: `a7094c72da4efa1c130fd914f03abb411fc5711bbf4a57f22adc8faf6a4d3215` (matches the installed study artifact).
- Export provenance: `prompted-human-pilot`; OS: iOS 27.0. The user supplied the export from the iPhone used for the study. The schema itself records only generic `iPhone`, not the hardware model.
- Eight unique planned trial IDs, no unexpected IDs, no invalid-reason flags.
- Identical key rectangles in every round; surface 440 × 219 points. No recorded geometry changes.
- 258 contacts with exactly one down and one up each; no malformed/cancelled contact streams.
- **All 258 lift-off coordinates resolve to the recorded keys using the actual Swift production resolver.** No substitute Python implementation was used.
- Reconstructing text from the recorded commits, including shift and deletion, matches every saved final string. Action and backspace counts also match.
- Raw contact data remains in the user-supplied attachment and ignored local analysis outputs, not in tracked source files.

These checks establish internal consistency of this export. They do not establish every physical touch was delivered by UIKit, nor turn the study app into an extension-host test.

## Observed results

Each condition contains the same two phrases: 64 reference Roman characters including spaces. Rates below pool characters and elapsed typing time across the two phrases. They are **characters/minute, not words/minute**. Errors are case-sensitive final-text edit operations against the exact prompt.

| Recorded posture | Routing | Final errors / 64 | Backspaces | Typing time | Characters/minute | Median release → commit |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| One thumb | Release 112 control | 2 | 0 | 12.50 s | 307.2 | 20.30 ms |
| One thumb | Ordered rollover | 3 | 0 | 26.32 s | 145.9 | 20.41 ms |
| Two thumbs | Release 112 control | 1 | 0 | 12.49 s | 307.4 | 20.38 ms |
| Two thumbs | Ordered rollover | 1 | 1 | 15.21 s | 252.5 | 20.34 ms |

The candidate's observed rate is about **17.9% lower with two thumbs** and **52.5% lower with one thumb**. These are descriptive differences from this session, not causal estimates. Equal-weight posture averaging would conceal too much; keep the conditions separate.

### Why the speed differences need care

The order was:

1. Two thumbs: candidate, two phrases.
2. Two thumbs: control, the same phrases again.
3. One thumb: control, two phrases.
4. One thumb: candidate, the same phrases again.

There was approximately a 97-second break between rounds 6 and 7. That break is **not** included in either trial's duration, but a change of grip, attention, or pacing could still matter. Handedness and whether the grip changed are not recorded; clarification was requested. The dataset labels describe the instructed posture, not an independent sensor measurement of which fingers were used.

Finger-down duration is approximately 54 ms at the median in all rounds. Median inter-contact gaps in rounds 5–6 were approximately 125/121 ms, versus 229/217 ms in rounds 7–8. The slower final rounds therefore contain longer intervals between contacts. This does not prove the interface had no influence on pacing.

Release-to-commit medians remain around 20 ms and p95 values around 29 ms in every condition. This is an application callback measurement, **not visible screen-response latency**. The traces show no contact queue waiting: no later delivered contact started before an earlier delivered contact ended.

## The rollover hypothesis was not exercised

There are **zero observed overlaps**, including in the candidate arm where multi-touch is enabled. The controlled UIKit regression still proves that Release 112's single-contact handler drops a directly delivered overlapping second touch, and that the candidate preserves it. This particular human session cannot measure the benefit of that fix.

The baseline may suppress second touches before the logging view sees them, so “no observed overlap” must not be rewritten as “no physical overlapping tap was possible.” Nevertheless, no dropped/reordered **delivered** contact is present, and all saved final strings can be reconstructed from their commits.

The spatial resolver and frames are shared between the two study arms. The same coordinate therefore gets the same key in either arm. A different wrong key in two separately typed attempts is not evidence that rollover changed the key boundaries.

## What the wrong taps reveal

The intended letters in this table come from the exact prompt, with direct position alignment in trials without edits. They are prompt labels, not independent measurements of what the user meant to press.

| Round | Prompt / observed | Recorded lift-off point | Interpretation |
| --- | --- | --- | --- |
| 1, candidate/two thumbs | Final `o` initially became `i`, then was corrected | x 343.33, y 26.33 | About 6.33 pt inside the I side of the I/O boundary; one explicit correction. Final phrase is exact. |
| 2, candidate/two thumbs | `bikale` → `bimale` (`k` → `m`) | x 358.33, y 106.67 | The K/M row boundary is y 106.50. The sample is only **0.17 pt** into the lower row. A useful ambiguous-boundary example. |
| 4, control/two thumbs | `bikale` → `bikele` (`a` → `e`) | x 106.00, y 15.33 | Inside E, far from A. Not a plausible tiny A-boundary miss. |
| 6, control/one thumb | `k` → `j` | x 326.33, y 81.33 | About **2 pt** on the J side of the J/K boundary. Another useful boundary case. |
| 6, control/one thumb | `a` → `e` | x 106.00, y 18.00 | Again inside E. Do not relabel this as an A touch for calibration. |
| 8, candidate/one thumb | `a` → `e` | x 125.00, y 34.67 | Inside E; same prompt mismatch again. |
| 8, candidate/one thumb | `nodir` → `nidir` (`o` → `i`) | x 349.67, y 31.33 | Essentially on the I/O boundary. The resolver picks I. The exact boundary tie is not evidence of a numerical bug with an objectively correct O outcome. |
| 8, candidate/one thumb | `hobe` → `hobr` (`e` → `r`) | x 162.00, y 17.00 | Inside R, around 29 pt beyond the E/R boundary. A small local offset is not a justified remedy. |

The repeated `bikale`/`bikele` discrepancy may reflect transcription, an intended Roman spelling variant, or another user decision. The coordinates alone do not distinguish those causes. Exact-prompt CER counts it as an error, but training an A target from these central E taps would contaminate the touch model and make deliberate E input less predictable.

The K/M event also shows why “nearest center” is not an automatic fix: this point is slightly closer to M's visual center than K's. A useful improvement needs calibrated spatial evidence and/or word-level interpretation, not merely replacing row-first selection with Euclidean distance.

## What changes are justified now

1. **Measurement:** flag partial exports explicitly; retain a reproducible integrity/latency/spatial replay report. Implemented and checked against both supplied exports.
2. **Routing:** retain the regression-proven rollover candidate, including its command-switch cancellation tests. No general speed/accuracy claim from this pilot.
3. **Spatial experiments:** preserve the K/M, J/K and I/O examples as diagnostic cases, with the many already-correct neighboring taps as negative controls. Do not adjust a global row boundary to rescue one point.
4. **Next study:** add a clearly separate practice phase, explicit left/right thumb and grip labeling, more varied prompts, and a short overlap task. Natural typing and intentional-overlap results must be reported separately.
5. **Personalization:** obtain a separate calibration session and freeze a later held-out session before fitting. This pilot's repeated two-phrase set does not support a model claiming to handle all letters, grips, names or Bangla orthography.
6. **Language:** retain literal Roman input and predictable key centers. Evaluate transliteration-aware alternatives at word level against independently reviewed Bangla targets; these motor-task strings alone do not label Bangla correctness.

A new model should first run offline or in shadow mode, so its proposed decisions can be compared against the existing resolver without changing the user's text. Only advance a candidate after it reduces relevant errors without materially worsening correction burden or speed in either posture.

## Reproduce

```sh
scripts/analyze-accuracy-pilot.py /path/to/complete-session.json
```

Outputs under ignored `build/TypingAccuracyPilot/`:

- `report.json`: Swift text scores, paired deltas and completeness.
- `replay.json`: actual-production-resolver decisions for recorded down/up points.
- `audit.json`: source hash, consistency checks, trial timing and condition summaries.
- `pilot-summary.png` / `.svg`: standalone comparison chart.

The spatial replay deliberately rejects unsupported key tokens and does not claim to simulate UIKit delivery, predict physical touches that were never logged, or infer the user's intent. The Python text-event audit is limited to this ASCII Roman motor task; Unicode string scoring remains in Swift.

Verification: seven metric/report tests passed, including partial-export detection. The complete human export passed the spatial, event-count and final-text integrity checks described above. No raw human trace was turned into a unit-test fixture or a training set.
