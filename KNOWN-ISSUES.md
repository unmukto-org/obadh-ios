# Known issues

Last updated: 2026-09-25. Scope: the unreleased v1.0.1 integration.
The installed everyday keyboard is Release 112 (`a0abe32`); merging source into
`main` does not update that installation. The App Store baseline remains `v1.0`.

Statuses distinguish **open, reproduced**, **needs behavioral verification**,
and **fixed in source**. A passing simulator test is not a physical-device fix.
Keep stable issue IDs, record dated evidence and corrections, and retain resolved
entries so future regressions can be traced. Do not close an issue on a branch
name, a plausible explanation, or an expected test failure.

## Open issues

### KI-001 — Suggestion zone changes height after keyboard switching

- **Priority/status:** High; open, reproduced on iOS 27 hardware and iOS 26.5 simulator.
- **Symptom:** The visible area above the keys can become roughly 17 points
  shorter after system Emoji → Obadh and recover after foregrounding. Messenger
  is one observed host. Not every reported cold-start case is proven identical.
- **Evidence:** Obadh's ribbon and key positions can remain unchanged while the
  host-owned top margin changes. A standalone public UIKit keyboard reproduces
  the discrepancy without Obadh's engine or layout. This supports a host-side
  mechanism for this reproduction, not an Apple-confirmed diagnosis of all cases.
- **Attempts:** Height pulses, sizing variations, view replacement and host
  refresh experiments have not provided a reliable physical-device fix.
  Unconditional compensation can make the ribbon too tall and must not be
  described as a solution. A diagnostic override caused a separate tall case.
- **Resolution evidence required:** Repeatable cold/warm switching and foreground
  checks on the iPhone, including Messenger and controlled hosts, with matching
  visible heights, stable key positions and working text entry. An expected
  failure in the Emoji test does not satisfy this requirement.
- **Evidence date:** 2026-09-25. See `docs/keyboard-investigation.md`,
  `docs/keyboard-key-color-investigation.md`, and `docs/keyboard-host-margin-followup.md`
  after their integration.

### KI-002 — Input can stop reaching the host after foreground return

- **Priority/status:** High; open, reproduced in controlled iOS 27 device tests.
- **Symptom:** A keyboard button action is received but `insertText` does not
  update the host. Reproduced with a minimal extension and the installed Obadh
  control; simulator behavior differs.
- **Limits:** An earlier automation result targeted a retained native Return
  element and was corrected. Everyday manual frequency is not established.
  Treat input delivery and height as separate failures even when they coincide.
- **Resolution evidence required:** Repeated physical-device foreground cycles
  with verified Obadh actions and host text mutation, including a native control.
- **Evidence date:** 2026-09-25. See `docs/keyboard-official-api-audit.md` and the
  foreground/input sections of `docs/keyboard-host-margin-followup.md` after integration.

### KI-003 — Remaining color/overlay flashes during switching

- **Priority/status:** Open; the exact cause of every reported device flash is
  not established. One distinct detached-key trait defect has a verified fix.
- **Scope:** Native backdrop changes or retained native layers may still affect
  compositing. Fixing key fill initialization does not establish seamless
  switching in all appearances and host apps.
- **Resolution evidence required:** Before/after physical-device switching
  captures in light/dark modes and relevant accessibility settings, separating
  Obadh fill changes from system backdrop/overlay changes.
- **Evidence date:** 2026-09-25. See `docs/keyboard-key-color-investigation.md` and
  `docs/keyboard-host-margin-followup.md` after integration.

### KI-004 — Overlapping touches and the candidate's waiting behavior

- **Priority/status:** Reproduced input loss in Release 112; candidate awaiting integration.
- **Evidence:** The single-contact handler drops a second overlapping touch in
  controlled UIKit traces. A queued candidate preserves touch-down order.
- **Candidate limitation:** A held first finger delays later commits and their
  preview/feedback. General human accuracy or speed improvement is unproven.
  The eight-round pilot contained no observed overlaps in the candidate arm and
  cannot measure this fix's benefit. Both one-thumb and two-thumb use matter.
- **Resolution evidence required:** Retain cancellation, command, ordering and
  iPad-flick regressions; validate intentional overlaps, resting fingers and
  natural typing on hardware. Keep controlled routing correctness separate from
  held-out human speed, accuracy and correction burden.
- **Evidence date:** 2026-09-25. See `docs/typing-accuracy-research.md` and
  `docs/typing-accuracy-pilot-2026-09-25.md` after integration.

### KI-005 — Host field traits need behavioral coverage

- **Status:** Needs behavioral verification; source-level implementation gaps,
  not a claim that every affected field currently fails.
- **Scope:** Email/URL/numeric layouts, Return label/action and automatic Return
  availability, host autocorrection preferences, and explicit keyboard appearance.
  The audit found these proxy traits were not read by the shipping controller.
- **Resolution evidence required:** Dedicated host editors exercising each trait
  and actual resulting text/actions before choosing a behavior change.
- **Evidence date:** 2026-09-25; `docs/keyboard-official-api-audit.md` after integration.

### KI-006 — Custom globe long-press behavior is unverified

- **Status:** Needs behavioral verification on iPad/Home-button layouts.
- **Scope:** Obadh's own globe advances input mode on release. The official
  template routes touch events to the input-mode-list handler. This does not
  diagnose the system-owned globe on Face ID iPhones or the height discrepancy.
- **Resolution evidence required:** Hardware checks of tap and long press where
  Obadh supplies the globe, then a regression test for any confirmed difference.
- **Evidence date:** 2026-09-25; `docs/keyboard-official-api-audit.md` after integration.

### KI-007 — Native appearance and typing-accuracy coverage is incomplete

- **Status:** Open validation work, not a single reproduced defect.
- **Scope:** Font measurements cover sampled modern portrait iPhones, not every
  orientation/device. Accessibility/material changes do not establish complete
  Liquid Glass parity. Spatial suggestion research has not produced a new decoder.
- **Accuracy evidence:** The pilot does not demonstrate improved human typing.
  Participant-confirmed `bikale` / `bikele` variants must both be accepted for
  that prompt; do not train intended A targets from those E contacts.
- **Resolution evidence required:** Expand measured appearance coverage and use
  separate calibration and held-out typing sessions with reviewed transliteration
  targets. Do not reuse the pilot to both tune and claim a model improvement.
- **Evidence date:** 2026-09-25; the typography and accuracy reports after integration.

## Resolved defects retained for regression tracking

Entries are added as the corresponding source changes are integrated. A source
fix and an installed build are recorded separately.

### KI-008 — Switching jump and lifecycle defects

Fixed in source; included in installed Release 112. Simulator recordings showed a 199–228 pt upward key-row jump before bottom anchoring and no corresponding jump in the sampled after captures. Regression tests cover fixed ribbon geometry, stale async suggestions, cancelled touches, delete cleanup, accessible activation and caps lock. This does not close KI-001 or KI-002.

Evidence and integration date: 2026-09-25.

<!-- Integration: fix/keyboard-presentation-lifecycle at d937705; 2026-09-25. -->
