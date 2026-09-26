# Known issues

Updated: **2026-09-25**. Only open issues and their relevant research belong here.
Resolved work belongs in [CHANGELOG.md](CHANGELOG.md). Do not create separate
research reports. Add dated evidence to the relevant issue; remove the entry when
its acceptance checks pass and record the resolution in the changelog.

**Scope:** unreleased v1.0.1 source. The phone still runs Release 112 (`a0abe32`).
Evidence comes from iPhone 16 Pro Max / iOS 27.0 (24A435) and an iOS 26.5
simulator; simulator success does not establish a device fix. External sources
below were reviewed during the September 25 investigation, not newly rechecked
while consolidating this file. Local evidence under `build/` is git-ignored.

| ID | Open issue | Status |
| --- | --- | --- |
| [KI-001](#ki-001) | Suggestion-zone height changes | High priority; reproduced, no reliable fix |
| [KI-002](#ki-002) | Foreground input fails to reach host | High priority; controlled device reproduction |
| [KI-003](#ki-003) | Remaining switching flashes/overlays | Exact cause and frequency not established |
| [KI-004](#ki-004) | Overlap candidate can delay input/feedback | Hardware acceptance pending |
| [KI-005](#ki-005) | Host field traits | Behavioral verification needed |
| [KI-006](#ki-006) | Custom globe long press | Behavioral verification needed |
| [KI-007](#ki-007) | Native appearance coverage | Incomplete verification |
| [KI-012](#ki-012) | Human typing accuracy | No demonstrated improvement yet |
| [KI-013](#ki-013) | Letter-key shortcut for ৎ | iOS mapping design pending |

<!-- feedback-draft:start -->
<a id="ki-001"></a>

## KI-001 — Suggestion-zone height changes

**Known:** Emoji → Obadh can remove roughly 17 pt above the ribbon; foregrounding
can restore it. Observed in Messenger and controlled hosts. Our actual ribbon,
key positions and requested content height can remain unchanged. Not every
reported cold-start or tall-ribbon case has been shown to share this mechanism.

| Controlled sequence: English → custom / Emoji → custom / foreground | Total host heights (pt) |
| --- | --- |
| Minimal 180 pt UIKit extension, simulator and physical phone | 316 / 299 / 316 |
| Normal Obadh, simulator | 389 / 372 / 389 |
| Normal Obadh, physical phone | 391 / 374 / 391 |

The minimal extension excludes Obadh's engine, layout and touch routing. Its root
stays 180 pt; the difference is outside that root. Simulator-only runtime tracing
found retained native keyplane top padding 7 after English and 0 after Emoji;
extra padding was respectively 17 and 0 (`24 - top` when top is nonzero).
This explains that simulator reproduction, not verified iOS 27 internals or an
Apple-confirmed diagnosis. Private tracing is excluded from shipping targets.

### Attempts and why they did not solve it

| Attempt | Result / reason rejected |
| --- | --- |
| Explicit `.keyboard` / `.default` roots; self-sizing off; required height; explicit fitting size | Minimal simulator still 316 / 299. Correct content sizing did not stabilize host padding. |
| Intrinsic size, `sizeThatFits`, preferred size only, or wholly system-chosen height | 360 / 343. Content height also differed from the requested 180; host difference remained 17. |
| Height pulses: one pixel and 180 → 197 → 180 | No recovery in completed comparisons. Physical 255 → 272 → 255 also failed after both commands were confirmed consumed. |
| Apparent device pulse recovery | False positive: reset was not consumed, leaving a larger request. Completed repeat kept outer top at 626.67 and q row at 662. |
| Replace view shell, plain UIView root, renew self-sizing/intrinsic/layout state | Margin difference remained. Async clearing/rebuilding `inputView` lost the working test key; rejected for breaking input. |
| Collapse height to zero then restore | UIKit granted 224 rather than zero, then 180; final margin difference remained. |
| Single native material surface instead of nested surfaces | Simulator 389 / 372 / 389; device 391 / 374 / 391. Native overlap also remained. Experiment removed from production; source at `2af5d8e`. |
| Language changes, early language assignment, `PrimaryLanguage` / `IsASCIICapable` metadata, dictation-key refresh | Completed simulator comparisons retained the discrepancy. |
| Zero-distance cursor move, empty insertion, supplementary lexicon request | No recovery. Empty insertion can affect editing. Lexicon probe initially used the wrong callback queue; corrected probe still failed to repair height. |
| Same-orientation scene geometry request; keyboard-type setter | Scene rejected geometry changes; proxy lacked the optional setter. These were unavailable operations, not successful refreshes. |
| Reload extension responder | No owned host responder found; proxy does not implement `reloadInputViews`. |
| Owning host calls `reloadInputViews()` | Repairs simulator height, but physical phone stays 374. Extension cannot call it on another app's editor. |
| Host resigns/reacquires first responder | Sometimes restores 391; other repeats remain 374 or switch to native English. Not reliable or seamless. |
| Detect missing band from bounds, safe areas, window, layout guide, screen conversions, public traits, input mode, lifecycle traces | Normal/short presentations exposed matching values. No reliable compensation signal established. |
| Add 17–18 pt unconditionally | Produces an oversized zone when the OS band is present. No automatic compensation is enabled. |

**Research:** Apple's [custom keyboard layout](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface)
and [self-sizing](https://developer.apple.com/documentation/uikit/uiinputview/allowsselfsizing)
APIs govern requested content sizing; they do not promise fixed outer padding.
[Host reload](https://developer.apple.com/documentation/uikit/uiresponder/reloadinputviews())
belongs to the responder owner. A [matching forum report](https://developer.apple.com/forums/thread/843093)
references FB21449121 / FB24460699, but supplies no Apple-confirmed remedy.
Checked iOS 27 release notes and KeyboardKit release notes did not establish a
fix. Compatibility mode is not universally absent on iOS 27
([Apple clarification](https://developer.apple.com/forums/thread/838637)); do not
infer Messenger's presentation from its name or enable unvalidated iOS 26 anchors.

**Reproduce/evidence:** `scripts/parity/package-margin-feedback.py` generates a
separately identified public-API keyboard and host with a 44 pt accessory;
`testHeightIsStable` asserts equal settled heights. `generate-margin-probe.py`
contains simulator variants; it replaces the simulator's Obadh, so use a dedicated
simulator and restore the normal app. `generate-margin-host.py` tests the installed
keyboard. Device tests use `-collect-test-diagnostics never`. Evidence:
`build/host-margin-investigation/`, especially `host-trace-foreground/`,
`device-verified-glass-and-pulse/`, `device-single-surface/` and `logs/`.
No feedback has been submitted.

**Acceptance:** Repeat cold/warm launch, English/Emoji switching and foregrounding
on hardware, including Messenger and controlled accessory hosts. Require stable
visible height, key positions, selection and text entry. An expected height
failure is still a failure to meet this requirement.

<a id="ki-002"></a>

## KI-002 — Foreground input can stop reaching the host

**Known:** On iOS 27 hardware, the minimal extension's button action runs but
`insertText("a")` does not update the focused host within three seconds. Context
length stays 6, `hasText` is true, and the public document identifier changes.
Reproduced in controlled tests of installed Obadh too. Everyday manual frequency
and the underlying mechanism remain unconfirmed.

| Control / attempt | Observation |
| --- | --- |
| Fresh minimal extension / fresh Obadh presentation | Insertion works. |
| Immediately after Emoji switch | Insertion works despite the shorter container. |
| Foreground without visiting Emoji | Fails even with unchanged total height: distinct from KI-001. |
| Native English foreground control on phone | Passes. |
| Same custom-keyboard foreground test on iOS 26.5 simulator | Passes; cannot clear the hardware failure. |
| Earlier apparently passing Obadh automation | Discarded: ambiguous query selected retained native lowercase `return`. Exact Obadh label `Return` reproduces failure. |

A delivered tap alone is not successful input. Apple documents
[`textDocumentProxy`](https://developer.apple.com/documentation/uikit/uiinputviewcontroller/textdocumentproxy)
and [`documentIdentifier`](https://developer.apple.com/documentation/uikit/uitextdocumentproxy/documentidentifier),
but the audit found no public reconnect operation. A relationship to retained
native layers is a hypothesis, not an established mechanism. Switching to marked
text would change composition semantics and is not an evidenced remedy.

**Reproduce/evidence:** Standalone `ReproTests.swift`: `testInputWorks`,
`testInputAfterEmoji`, `testInputAfterForeground`,
`testInputAfterForegroundWithoutEmoji`, `testNativeInputAfterForeground`.
Keep these separate from height assertions; captures/logs are under
`build/host-margin-investigation/`.

**Acceptance:** Human-operated confirmation plus repeated controlled device
foreground cycles verifying both Obadh action delivery and actual host mutation,
with native control, unchanged focus/selection and no lost or duplicate text.
<!-- feedback-draft:end -->

<a id="ki-003"></a>

## KI-003 — Remaining switching flashes and native overlays

**Known:** The user reported momentary key-background changes. Physical captures
also contain retained native keyplanes. The detached-key fill defect recorded in
the changelog does not establish that every flash is fixed.

**Tried / limits:** A sampled light-mode space-key patch stayed RGB 245 through
switching; this cannot rule out dark-mode or device-compositing flashes. The
single-surface experiment left physical native overlap visible. No evidence yet
justifies hiding the native backdrop or replacing it with an opaque surface.
[Apple's effect-view guidance](https://developer.apple.com/documentation/uikit/uivisualeffectview)
identifies opacity/snapshot interactions, but does not diagnose this report.
[Similar developer observations](https://developer.apple.com/forums/thread/845726)
are not an Apple-confirmed cause or workaround.

**Next / acceptance:** Capture physical English/Emoji → Obadh transitions in
light/dark and accessibility modes; distinguish key fills, backdrop and native
overlay frames. Require repeatable before/after disappearance of the identified
flash without altered settled appearance. Evidence: `build/key-color-investigation/`
and `build/host-margin-investigation/device-single-surface/`.

<a id="ki-004"></a>

## KI-004 — Overlap candidate waits behind a held finger

**Status:** Unreleased touch queue needs physical acceptance; Release 112 still
uses the old handler. The corrected dropped-contact defect is in the changelog.

**Known:** The candidate orders commits by touchdown, retaining each finger's
lift-off coordinate/flick origin. A later released contact waits for the first
finger to finish or cancel; its preview/feedback also waits. This preserves serial
delete/shift ownership, but can delay typing when a finger rests on the keyboard.

**Tried / limits:** UIKit regressions cover reverse releases, batched contacts,
retargeting, cancellation, duplicate ends, row rebuild/dismissal, commands,
delete order, iPad flicks and the real composer. These do not establish comfortable
human interaction. The pilot contained no observed candidate overlaps.
Committing an unfinished earlier contact on the next touchdown, or separate
per-contact feedback, are unimplemented alternatives requiring modifier/flick
and cancellation tests. Do not infer absent physical overlap from baseline logs:
UIKit may suppress the second contact before that handler records it.

**Acceptance:** Hardware overlap and resting-finger tasks plus natural one-thumb
and two-thumb typing, evaluating input order, latency, previews, correction burden
and speed separately. Tests: `KeyboardTouchAccuracyTests.swift`; research basis:
[UIKit multiple-touch delivery](https://developer.apple.com/documentation/uikit/uiview/ismultipletouchenabled).

<a id="ki-005"></a>

## KI-005 — Host field traits need behavioral verification

**Known:** Source audit found no controller reads of host keyboard type, Return
style/automatic availability, autocorrection preference or explicit keyboard
appearance. This is an implementation observation, not proof every such field
fails; attached view traits might already convey appearance.

**Research / next:** [UITextInputTraits](https://developer.apple.com/documentation/uikit/uitextinputtraits)
and Apple's local extension template expose these capabilities. Build dedicated
email, URL, number, search and autocorrection-disabled editors, plus explicit
dark-in-light/light-in-dark keyboard requests. Verify actual layout, Return action,
empty-field enablement and text before fixing a confirmed divergence. Preserve
Bangla composition. Supplementary lexicon support is optional, not missing setup;
its separate height experiment did not resolve KI-001.

<a id="ki-006"></a>

## KI-006 — Custom globe long press needs verification

**Known:** Obadh's own globe calls `advanceToNextInputMode()` on release. Apple's
[creation guide](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard)
and local template route touch events to `handleInputModeList(from:with:)`.

**Scope / acceptance:** Test tap and long press on iPad/Home-button layouts where
Obadh supplies the globe. Reproduce any missing mode-list behavior before changing
routing; then verify tap, hold and cancellation. Face ID iPhones normally use a
system-owned globe, so this observation does not diagnose their height issue.

<a id="ki-007"></a>

## KI-007 — Native appearance and accessibility coverage is incomplete

**Known:** Portrait typography has sampled native comparisons; exact private font
identity and all layout/script combinations are not established. Existing iPad
and landscape geometry gates do not prove current device appearance everywhere.

**Tried / limits:** Untinted glass on every key passed interaction tests but made
dark key faces about RGB 32 (20–21 with accessibility settings), versus native
78–79 (128–129); rejected. Native keyboard material plus thin overlays remains the
implementation. Device glass-slider endpoint checks and simulator accessibility
toggles are limited evidence, not complete Liquid Glass parity. Apple recommends
[native material adoption](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
and [appropriate material layering](https://developer.apple.com/design/human-interface-guidelines/materials),
not simply adding glass to every key. Named-font guessing was also rejected:
an unavailable candidate silently fell back to Times New Roman.

**Remaining checks:** Pressed colors; iPad/landscape colors and suggestion zones;
emoji panel/search; flick animation; Bengali shaping and unmeasured typography;
physical VoiceOver typing modes. Current pixel gates omit the command row;
its widths have layout tests only. Use `scripts/parity/all.sh` and the individual
phone/iPad geometry/type tools for their stated coverage, then hardware captures.
Keep public system fonts; [Apple typography guidance](https://developer.apple.com/design/human-interface-guidelines/typography)
does not publish the native keyboard's exact font recipe. Do not claim exhaustive
parity from passing geometry rectangles or sampled glyphs.

<a id="ki-012"></a>

## KI-012 — No demonstrated human typing-accuracy improvement

**Pilot:** Eight rounds, 258 delivered contacts, shared 440 × 219 key frames;
production-resolver replay, event counts and final strings agree. Two repeated
phrases, one participant and condition order limit inference. A 97-second break
before the last round is excluded from trial time, but grip/attention changes are
unknown. The first supplied export had only six rounds; analysis flags it partial.

| Posture | Control / candidate reference errors (per 64 chars each) | Control / candidate chars/min |
| --- | --- | --- |
| Two thumbs | 0 / 1 | 307.4 / 252.5 |
| One thumb | 1 / 2 | 307.2 / 145.9 |

These are descriptive, not causal estimates. Median release-to-callback was
about 20 ms in all conditions, not measured screen latency. Slower trials had
longer inter-contact gaps. No observed candidate overlaps exercised KI-004.

**What the traces support:** `bikale` and `bikele` are participant-confirmed valid
dialect choices. Do not treat their A/E difference as a targeting mistake.
K/M and J/K misses were about 0.17 pt and 2 pt across boundaries; I/O was essentially
on the boundary. The E/R miss was about 29 pt inside R. Nearest-center selection
would still choose M in the K/M example. A global offset is not justified by
these examples. The engine probe already finds several desired corrections in
existing suggestions; it does not implement a better spatial decoder.

**Research and decisions:**

- [Gboard spatial personalization](https://arxiv.org/html/2209.11311): better spatial
  fit need not improve typing; use regularized models and held-out behavioral
  outcomes. Its Android effect sizes/settings are not Obadh guarantees.
- [Bayesian Touch](https://research.google/pubs/bayesian-touch-a-statistic-criterion-of-target-selection-with-finger-touch/)
  and [transliterated input via WFSTs](https://aclanthology.org/W17-4002/): retain
  plausible Roman paths until language scoring, but preserve deliberate key
  centers, literal input, case-sensitive rules, names and dialects. Proposed only.
- [How We Type](https://userinterfaces.aalto.fi/how-we-type-mobile/) and
  [text-entry error metrics](https://www.yorku.ca/mack/CHI01a.htm): measure speed,
  final errors and correction effort, separately for each posture. Backspaces
  alone are not the formal corrected-error rate; Roman and Bangla units differ.
- [UIKit preciseLocation](https://developer.apple.com/documentation/uikit/uitouch/preciselocation(in:))
  is discouraged for hit testing; touch radius is approximate and predicted
  touches are not committed input. Raw capacitive heatmaps are not supplied by
  these public APIs. Gesture/speech/LLM studies do not validate a tap decoder.
- [Dakshina](https://github.com/google-research-datasets/dakshina) is a possible
  Bengali language benchmark, not finger data or guaranteed Obadh romanization.
  No corpus/model was imported. Any use needs reference review and attribution.

**Next / acceptance:** Practice phase, hand/grip labels, more varied prompts,
separate intentional-overlap tasks, then separate calibration and frozen held-out
sessions. Weight one-thumb/two-thumb use equally but report each. Evaluate offline
or in shadow mode first; require fewer errors without material speed/correction
regressions. Do not tune and claim success on the same two-phrase pilot.

**Reproduce:** `scripts/analyze-accuracy-pilot.py /path/to/session.json` uses native
resolver replay and the explicit session reference policy in
`Tools/TypingAccuracy/ReferencePolicies/`. It preserves exact-copy scores alongside
accepted variants; raw phone traces are not committed or used as training fixtures.
Outputs: `build/TypingAccuracyPilot/{report,replay,audit}.json` and summary charts.
The standalone lab logs prompted study input only, not everyday keyboard typing.

<a id="ki-013"></a>

## KI-013 — Letter-key shortcut for খণ্ড ত (ৎ)

**Known:** Engine 0.9.3 supports <code>t``</code> / <code>T``</code> for ৎ, but
there is no convenient letter-only alias on the phone. Current `tq` produces ৎক
through defensive `q` → ক matching; that fallback is not a reason to reserve the
combination, per user clarification.

**2026-09-25 design feedback:** The engine team recommends mapping keyboard input
to the existing canonical signals in iOS. Globally redefining `q` would affect
`iraq` and other clients. A contextual `tq` alias would not redefine all `q`s,
but an iOS-only mapping is also viable. Single-Q handling and `qq` precedence
must be explicit; blindly emitting two backticks on every Q loses that distinction.
Keep original keys separately from any normalized engine input.

**Constraints / acceptance:** Preserve `tt` → ত্ত, `tqq` → তঁ, existing explicit
signals and deliberate case rules. Verify whole words, correction queries and
incremental input through whichever mapping is selected. `qq` deletes as one
chandrabindu unit; `tqq` → `tq` should restore ৎ once that input actually renders
the intended intermediate form. The deletion exception has a contract fixture,
but neither the bundled engine nor the iOS input path currently implements the
new shortcut. No new Q remapping has been enabled.
