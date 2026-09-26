# Changelog

This is a plain-language record of work since the last release. Unreleased work
is not a promise that a reported issue is fixed or that a build is on a device.
Current limitations and verification requirements live in [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

## Unreleased

No changes after the v1.0.1 release preparation yet.

## v1.0.1 — 2026-09-25 (uploaded for release)

Version: `1.0.1` (build `168`). Engine: `0.9.4`.
Prepared and uploaded: 2026-09-25. App Store publication date: pending.
Tag: `v1.0.1` (annotated).
Tested source commit: `a254af68e39a4ddaac4da55196a971f06d9526cc`.
Comparison: [v1.0…v1.0.1](https://github.com/nsssayom/obadh-ios/compare/v1.0...v1.0.1).
This metadata is recorded in a documentation commit after the tagged archive
source; the tag and binary continue to identify the tested source above.

### Release verification

- Uploaded build 168 through Xcode's signed-in account. Xcode reported
  **Upload succeeded** and **Uploaded package is processing** on 2026-09-25.
  The owner will finish App Store Connect build selection, metadata and App Review
  submission. This is an upload, not confirmation of review approval or publication.

- Passed all 152 Swift and 54 UIKit tests on the release source. Engine 0.9.4
  had already passed the 19 real-engine integration tests before the version bump.
- Created a signed Release archive from the clean tagged source. Verified matching
  app/extension version `1.0.1`, build `168`, source `a254af68` and strict signatures.
- Corrected the build-stamping console message to read the marketing version
  from project.yml instead of reporting the obsolete hard-coded `0.1.0`.

### App Store update notes

- English loanwords now default to their Bangla spelling. Tap the quoted second
  suggestion to keep the literal transliteration.
- Type `tq` for ৎ and `qq` for ঁ, with more consistent backspace behavior.
- Added typing sounds, including distinct sounds for special keys, with an app
  setting to turn them off.
- Improved keyboard appearance, accessibility, touch handling and feedback.
- Updated the transliteration engine and added its version to About.

The open height, foreground-input and device-verification issues remain in
KNOWN-ISSUES.md; this update does not claim to resolve them.

### 2026-09-25

#### Fixes and changes

- Upgraded the linked engine from **0.9.3 to 0.9.4** and updated the Cargo lockfile;
  no other dependency changed. Rebuilt all three device/simulator Rust slices.
  The vendored C header is byte-for-byte unchanged (ABI 2). This brings the
  engine's ZWJ-based র‍্য output, productive ট্র্য-style conjuncts, joiner-free
  গ্ণ/ঙ্ক্ত/স্প্ল, live ত before ল, and stricter learned-word joiner validation.
  Bundled language artifacts are unchanged. About reads the linked version
  automatically; the installed phone build still used 0.9.3 at that point.


- Made exact English loanwords the default Bangla candidate, regardless of
  Auto-Insert Corrections. The engine already matches case-insensitively; no
  engine update or iOS case rewriting was needed. Exact matches bypass typo
  costs, frequency thresholds and learned-word protection. The preferred Bangla
  spelling leads the ribbon; the quoted, tappable literal is second. The inline
  preview stays literal, and fuzzy matches retain the existing correction rules.
  Updated Settings copy and policy documentation. This resolves KI-015.

- Removed the timing dependency for exact loanwords: Space, Return and punctuation
  resolve an unfinished query at commit. Background suggestions now use one
  detailed engine traversal for both candidates and provenance, instead of two
  traversals with auto-insert enabled. No full search runs on letter previews.
  Immediate-commit samples took 1.3–5.4 ms in the simulator; physical-device
  latency has not been measured. The phone remained on Release 162 at that point.


- Added **Engine Version** to About → Version and Copy Build Details. It reads
  the linked engine's own version function, independently of the app version and
  C ABI version, without creating an engine or loading language models. Verified
  the rendered value **0.9.3** in the simulator; rebuilt the bridge with the
  existing locked dependency and checked the portable Swift build.

- Hardened feedback without Full Access: skip sounds, haptic fallback impacts,
  preparation and engine startup. Revoking access invalidates pending engine
  callbacks and stops an existing engine asynchronously. Keystrokes never retry
  a failed engine. A failing regression confirmed 5,000 fallback impacts and
  5,001 preparations were reachable without access before this fix; this checks
  calls, not a newly reproduced device slowdown.

- Added the phone-confirmed special-key sounds: backspace and held delete use
  system sound 1155; return, space, shift, layout switches and emoji use 1156.
  Letters and suggestions retain UIKit's input click. The owner accepted the
  probe's sound and mute/settings checks before integration. The app switch and
  Full Access gate every sound type. Removed resolved KI-014. No loudness tuning
  was applied; Return's perceived level difference was not measured. Numeric IDs
  remain undocumented and need rechecking with future iOS versions.

- Removed the temporary sound-comparison app sources after testing; its code and
  findings remain in Git history. Retained regression tests and tools supporting
  the remaining open issues.

- Initially enabled UIKit keyboard clicks on the actual input view (the audio protocol was
  previously on its controller). Added an independent, persistent **Typing Sounds**
  switch in the app, on by default. Sound requests require Full Access and the app
  preference; UIKit retains control of Silent Mode, system keyboard sounds and
  volume. Updated setup and privacy copy. That initial implementation used
  `playInputClick()` exclusively; the later special-key refinement above adds
  differentiated sounds without changing the audio session.

- Removed iOS's duplicate `qq` → `^` rewrite after verifying that the bundled
  engine already handles chandrabindu. The composer preserves raw Roman input
  while treating completed `qq` as one deletion unit: `baqq` (বাঁ) → `ba` (বা).
  Single `q`, case distinctions and explicit `^` remain engine-defined.

- Corrected the initial follow-up's deletion policy after user clarification:
  removing the duplicate rewrite must not turn chandrabindu backspace into a
  stray ক. The earlier `baqq` → `baq` behavior and its test expectations were
  inappropriate. Repeated pairs now delete together; an unpaired final Q deletes
  separately. The later modifier-deletion refinement below removes the initial
  `tqq` → `tq` exception.

- Implemented the iOS `tq` / `Tq` → ৎ shortcut (KI-013) using the existing engine
  double-backtick signal. `sotq`, `utqsob` and `bidyutq` produce সৎ, উৎসব and
  বিদ্যুৎ. `qq` has precedence: `tqq` → তঁ.
  Preserved raw keystrokes and used identical canonical input for preview,
  suggestions and detailed correction queries. No engine update or global Q
  remapping was made. Removed the resolved issue from KNOWN-ISSUES.md.

- Refined modifier deletion after user testing: one backspace removes the whole
  Q modifier, so both `tqq` and `tq` return directly to `t`. The same rule applies
  inside words and after uppercase T. Repeated Q pairs retain their existing
  grouping; ordinary `qq` still deletes as one unit.

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

- Installed and launched signed Release **1.0 (166)** from `6ab7ab68` on the
  iPhone 16 Pro Max: engine **0.9.4** and exact-loanword defaults are now on the
  phone. Verified strict signatures, matching app/extension build and source
  stamps, and CoreDevice's installed version/build. This installation does not
  establish device acceptance for the remaining keyboard issues.


- Verified engine 0.9.4 using fresh DerivedData: 19 real-engine integration
  tests and 16 keyboard tests passed, including 14 scalar-level spelling cases,
  ABI/version checks, pinned artifact fingerprints, `tq`/`qq`, About's version,
  and all 112 loanword/case/setting combinations. Corrected two new test inputs
  to use explicit `O` for ও; the engine's vowel rules were unchanged. The unsigned
  iPhone Release build passed. No phone installation was performed.


- Verified the loanword change with 23 composer tests and 26 simulator tests
  covering the loanword policy, controller lifecycle and existing `tq`/`qq`
  shortcuts. The real-engine matrix checks 14 words × four case forms × both
  setting values (112 combinations), including protected literals. Checked
  immediate commit, quoted second-slot rendering and its registered tap action,
  stale-result invalidation, and fuzzy/unknown-source exclusion. The first tap
  test used UIControl event dispatch in a hostless bundle; corrected the test
  harness to invoke the registered target/action, then all five loanword tests
  passed. The unsigned iPhone Release build also passed; no build was installed.


- Checked 14 loanwords against engine 0.9.3 and the shipped dictionaries. All
  returned exact-loanword candidates; iOS's ordinary edit-cost ceiling blocked
  automatic insertion for 12, even with the setting enabled. Confirmed that the
  ribbon keeps the literal first and quotes it only when absent from the lexicon.
  Added a reproducible engine/composer probe and initially recorded KI-015.
  These findings describe behavior before the exact-loanword fix above.

- Installed and launched signed Release **1.0 (162)** from `1fb8c8a3` on the
  iPhone 16 Pro Max with the engine version in About and copied build details.
  Verified matching app/extension stamps, strict signatures and installed build
  162. The engine remains **0.9.3**; this change exposes its version, not an upgrade.

- Installed and launched signed Release **1.0 (159)** from `182dde0d` on the
  iPhone 16 Pro Max after merging differentiated sounds and the Full Access
  safeguards. Verified strict signatures, matching app/extension stamps and
  installed build 159. Confirmed both temporary phone apps were removed; also
  removed the simulator sound probe and its generated build directories. This
  remains an unreleased v1.0.1 development build; the `v1.0` tag is unchanged.

- Passed all 48 UIKit tests after the final sound and Full Access safeguards.
  The denial regression now observes zero sound requests, engine creations,
  fallback impacts and preparations over 5,000 events, including checks after
  revocation. A separate 1,000-key failure test confirms no per-key engine retry.

- Removed Sound Probe and Obadh Accuracy from the iPhone. Saved and parsed the
  accuracy-session JSON in `build/ReleaseAudit/AccuracyLabBackup-20260925/`
  before uninstalling the lab. Its source and measurement tools remain available
  for the still-open typing-accuracy investigation.

- Recorded the owner's Sound Probe 151 comparison: delete matches 1155;
  return/space/shift/123/emoji match 1156. Return loudness is a subjective follow-up,
  not a measured mismatch. Prepared an isolated key-specific playback candidate
  with unified app/Full Access gates and held-delete routing. It was held for
  Silent Mode and system Sound-off checks before the owner accepted integration.
  All 148 core tests and three focused UIKit sound tests passed.

- Built and signed standalone **Obadh Sound Probe 151** (`d55ee623`), inspected
  its simulator layout, and installed/launched it on the iPhone for sound/mute
  comparison. Obadh was then still on Release 149. The comparison app was a separate target;
  differentiated playback was subsequently integrated as recorded above.

- Followed up on the user's Release 149 listening report: clicks are audible, but
  special keys still use the letter sound. Audited Apple's sound-design guidance,
  current UIKit/AudioServices docs, SDK headers and KeyboardKit's implementation.
  Added a separate Release sound-comparison app to test three system sound IDs
  against UIKit and native English, including mute/settings behavior. Obadh's
  shipping playback was kept unchanged until the subsequent owner checks.

- Installed and launched signed Release **1.0 (149)** from `2f72b808` on the
  iPhone 16 Pro Max with typing sounds and the app switch. Verified strict
  signatures, matching app/extension stamps and CoreDevice's installed version.
  Listening and mute checks were pending at this point; the subsequent owner
  report supplied hardware evidence. Simulator tests are not audio acceptance.

- Verified the typing-sound protocol defect with a failing baseline, then passed
  148 core tests, 45 UIKit tests and three targeted UI checks. App sound toggling
  persists across relaunch; switching/foreground typing still passes. Emoji
  switching retains the known expected 389 → 372 → 389 pt host-height discrepancy.
  Corrected the new UI test to tap the actual trailing switch after its row-center
  tap did nothing; this was an automation error, not a settings defect.

- Installed and launched Release **1.0 (146)** from `4d6a94ec` on the iPhone 16
  Pro Max after the whole-modifier deletion refinement. The signed Release build
  passed, both app/extension stamps match, and CoreDevice confirms build 146.

- Built, signed, installed and launched Release **1.0 (143)** on the iPhone 16
  Pro Max from `1a58dc60` on 2026-09-25. Verified both bundle stamps, strict code
  signatures and absence of diagnostic trace markers; CoreDevice confirms the
  installed app's build is 143. Includes the `tq` shortcut and corrected `qq`
  deletion. This is a development-device installation, not the v1.0.1 release.

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

- The whole-modifier deletion regression failed before the correction; afterward,
  all 147 Swift and 43 UIKit tests passed. Coverage includes `tq` / `tqq`, uppercase
  T, modifiers inside words and repeated Q pairs against the bundled engine.

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
- During an authorized release, move the accumulated work into its version
  section and open a fresh Unreleased section. Distinguish preparation, upload,
  review submission and actual App Store publication dates. Never label a staged
  build as publicly released or move its tested source tag after upload.
