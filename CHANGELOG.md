# Changelog

This is a plain-language record of work since the last release. Unreleased work
is not a promise that a reported issue is fixed or that a build is on a device.
Current limitations and verification requirements live in [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

## Unreleased — planned v1.0.1

Release date: not set. Release tag and commit: not created.
Baseline: `v1.0` (`94c8132d594a4af5beec7ec12a5ef90b0ec8b169`).

### 2026-09-25

#### Fixes and changes

- Removed iOS's duplicate `qq` → `^` rewrite after verifying that the bundled
  engine already handles chandrabindu. The composer preserves raw Roman input
  while treating completed `qq` as one deletion unit: `baqq` (বাঁ) → `ba` (বা).
  Single `q`, case distinctions and explicit `^` remain engine-defined.

- Corrected the initial follow-up's deletion policy after user clarification:
  removing the duplicate rewrite must not turn chandrabindu backspace into a
  stray ক. The earlier `baqq` → `baq` behavior and its test expectations were
  inappropriate. Repeated pairs now delete together; an unpaired final Q deletes
  separately. The `tqq` → `tq` exception now uses the iOS mapping described below.

- Implemented the iOS `tq` / `Tq` → ৎ shortcut (KI-013) using the existing engine
  double-backtick signal. `sotq`, `utqsob` and `bidyutq` produce সৎ, উৎসব and
  বিদ্যুৎ. `qq` has precedence: `tqq` → তঁ; backspace returns to ৎ, then ত.
  Preserved raw keystrokes and used identical canonical input for preview,
  suggestions and detailed correction queries. No engine update or global Q
  remapping was made. Removed the resolved issue from KNOWN-ISSUES.md.

- Stabilized key-row positions during transient keyboard heights. Cancelled stale
  suggestions and touches on context changes, cleaned up held-delete timers, restored
  accessible key activation, and retained caps lock when typing.

- Fixed detached keys using the wrong appearance for their fill and updating only after
  a touch or refresh. Reset accidental debug sizing overrides that caused an extra
  18-point ribbon and isolated deliberate sizing experiments.

- Updated key overlays for Increase Contrast and Reduce Transparency, respected Reduce
  Motion for press feedback, and used a native glass primary onboarding button on iOS
  26+. Investigated host sizing without shipping an unverified height workaround.

- Adjusted modern portrait iPhone letter sizing and baselines against native captures:
  regular system font, 25 pt lowercase and 21.5 pt uppercase. Verified sampled glyph
  dimensions and baselines on the iPhone.

- Increased measured modern portrait suggestion text to 17 pt and the mode-switch
  label to 18 pt. Kept supported system fonts; exact private native font identity
  and complete device coverage are not claimed.

- Preserved overlapping contacts in touch-down order and cancelled queued input on
  emoji, globe and dismiss actions. Added a separate accuracy study app with a frozen
  Release 112 control, local exports, and reproducible metrics. Controlled regressions
  pass; human accuracy improvement remains unproven.

#### Investigation and testing

- Started a release journal and a single known-issues and research register.
  Reviewed the day's branches for sequential integration.

- Traced the retained native keyboard padding and added height regression checks.
  Confirmed that stable Obadh bounds do not imply a stable host-owned suggestion zone;
  no height fix resulted.

- Tested native-state refresh and sizing variations. Simulator-only successes did not
  transfer reliably to iOS 27 hardware; retained the unsuccessful results so they are
  not mistaken for fixes.

- Tested an isolated keyboard surface and built a standalone public UIKit reproduction
  of the height discrepancy. Added a physical-device height check; kept
  experimental/private tracing code outside shipping targets.

- Audited official keyboard APIs and investigated foreground input delivery. Reproduced
  a separate host text-mutation failure and corrected an automation false positive
  caused by selecting a retained native Return element.

- Audited the eight-round phone typing pilot with production-resolver replay, timing and
  event consistency checks. Added incomplete-export detection. The pilot did not
  demonstrate improved human typing accuracy or exercise candidate overlap handling.

- Accepted the participant-confirmed bikale/bikele dialect variants through an explicit
  session-scoped scoring policy. Preserved exact-copy scores and other errors; keyboard
  transliteration behavior did not change.

- Recorded bundled-engine suggestions for diagnostic pilot words as a portable XCTest
  attachment. This is an engine probe only; no spatial decoder or improved suggestion
  ranking was implemented.

- Corrected simulator keyboard activation and native-reference selection checks,
  and prevented detached debug controllers from consuming commands intended for
  the visible keyboard. Incomplete captures are not reported as parity passes.

- Built and installed Release 112 from `a0abe326`, with its version and signing
  checked. Later touch changes are in unreleased source, not that installed build.

- Consolidated ongoing research into the open issues in `KNOWN-ISSUES.md` and
  removed the ten standalone investigation/parity reports. Resolved work is
  recorded here; full historical reports remain in Git. Updated the reproduction
  packager to extract its height/input findings from the issue register.

- Integrated all 14 task branch tips in dependency order (12 merge commits;
  the device-validation and Release 112 branches were already included by
  ancestry). Preserved the published `v1.0` tag and the existing phone installation.

#### Integration verification

- The new `tq` word regressions failed before implementation. Afterward, 147
  Swift and 43 UIKit tests passed, including the real controller's asynchronous
  suggestion path, real-engine correction parity, whole words, commits, raw
  input preservation and forward/backward `tq` / `tqq` transitions. The Release
  iOS app/extension build also passed (compile check with signing disabled).

- The initial `qq` follow-up passed 145 Swift and 38 UIKit tests but encoded the
  wrong product expectation for deletion. Corrected semantic-deletion regressions
  failed against that change before repair. After repair, 146 Swift and 39 UIKit
  tests passed, covering paired/unpaired Qs, case, explicit `^`, suggestions and
  commit boundaries against the real engine. The future `tq` exception has a
  separate contract fixture at that stage; the later iOS mapping is now verified
  against the bundled engine's existing double-backtick signal.

- Passed 145 Swift core/metric tests, 33 UIKit lifecycle/touch tests, and 17
  real Swift/C engine integration tests on the integrated source.
- Built the app and extension in Release for iOS with signing disabled for this
  compile check. Checked that diagnostic trace/probe markers are absent. This
  was not an installation or a new physical-device acceptance run.
- Regenerated the Xcode project, checked local documentation links and Python
  syntax, and generated the standalone reproduction ZIP using only the open
  height/input findings. Branch ancestry and whitespace checks passed.
- The height discrepancy, foreground input failure and human-accuracy acceptance
  remain open. These successful integration checks do not close those issues.

## v1.0 — 2026-09-21 baseline

Version: `1.0` (build `105`). Tag: `v1.0` (annotated).
Commit: `94c8132d594a4af5beec7ec12a5ef90b0ec8b169`.
Date: 2026-09-21 (App Review submission/tag date).
Comparison: first release baseline; no earlier release recorded here.

- Prepared Obadh 1.0 (105) for App Review under `org.unmukto.obadh`.
- The existing annotated `v1.0` tag identifies `94c8132`. The pre-patch `main`
  merge commit, `9d9b890`, has exactly the same source tree. The published tag
  is preserved; this date records the submission baseline, not an independently
  verified App Store availability date.

## Maintaining this journal

- Add completed work under Unreleased, dated when it was integrated. Describe
  what changed in plain language; keep plans and unresolved symptoms in the
  issue register. Record investigations as investigations, not fixes.
- Update both files in the same change when an issue is resolved: remove it from
  KNOWN-ISSUES.md and record its ID, fix and verification here. While an issue is
  open, keep its relevant research, failed attempts and evidence in that file.
- Correct inaccurate claims explicitly. Keep released entries intact and add
  dated corrections when necessary.
- For each new release, use a `vX.Y.Z — YYYY-MM-DD` section and record the
  marketing version, build number, actual release date, annotated tag, full
  40-character release commit, and a comparison link/range from the previous
  release tag. Preserve the dated work entries below that metadata.
- Build and test the release commit first. Record that exact source SHA here in
  a following documentation commit, and point the annotated release tag at the
  tested source commit. This avoids inventing a self-referential commit hash or
  tagging a different binary source. Record the distinction if documentation
  changed after the build; never silently move an existing published tag.
- When v1.0.1 ships, move the accumulated Unreleased entries into its dated
  version section and start a fresh Unreleased section based on that tag. Do not
  create a release tag or claim a release date for ongoing work.
