# Testing and verification

Several layers, each aimed at a different failure class. The shared principle:
behavior is verified with real artifacts, input paths, and screenshots.
Measurements are paired with visual inspection; a passing subset does not prove
complete native parity.

## Unit tests (SwiftPM, off-device)

The pure logic (composer, text composition controller, emoji stores,
resolvers) builds as the `ObadhKeyboardCore` SwiftPM library and is
unit-tested against the *real generated artifacts* without a simulator.

## Engine integration tests (`Tests/ObadhEngineTests`)

This target links the actual `ObadhBridge.xcframework` and bundles the real
`ObadhModels` artifacts, so it exercises the true Swift↔C boundary:
opaque-handle lifecycle, packed-record decoding, snprintf-style sizing.
Artifact content hashes and canonical lexicon frequencies are **pinned** so an
engine or data bump that silently changes behavior fails loudly here. The
auto-insert gate's thresholds are calibrated by these tests against the real
lexicon (see [autocorrect.md](autocorrect.md)).

Run: `xcodebuild test -scheme Obadh -destination 'platform=iOS Simulator,...'`

## Controller lifecycle and real UI tests

`ObadhKeyboardLifecycleTests` compiles the actual controller, UIKit views, and
engine. It covers transient root sizes, stable ribbon height, async suggestion
invalidation, caps lock, held delete, cancelled touches, and accessible activation.
`ObadhKeyboardUITests` enables Obadh through Settings and exercises genuine
keyboard-menu switching, foregrounding, accessory views, system Emoji, landscape,
and finger input. Use a dedicated simulator; it changes its keyboard settings.

```sh
scripts/stamp-build.sh
xcodegen generate
xcodebuild test -scheme ObadhKeyboardLifecycleTests -destination 'platform=iOS Simulator,id=<UDID>' -jobs 2 CODE_SIGNING_ALLOWED=NO
xcodebuild test -scheme ObadhKeyboardUITests -destination 'platform=iOS Simulator,id=<UDID>' -parallel-testing-enabled NO -jobs 2 CODE_SIGNING_ALLOWED=NO
```

The Emoji/accessory test has an explicit expected failure for the system-owned
17-point margin discrepancy. Do not report that issue as fixed when the suite
passes. See [the September investigation](../KNOWN-ISSUES.md#ki-001) for evidence,
font audit tooling, and the remaining iOS 27 device checks.

`KeyboardFieldContextTests` supplies the public proxy contract to the production
controller and engine, including silent focus changes, stale suggestions, held
Delete, literal syntax, correction opt-outs, case and appearance. Voice delivery
tests verify destination binding across recreation and late results.

The DEBUG launch argument `--keyboard-field-test` opens actual email, URL,
numeric/decimal, search, OTP, Latin, uncorrected Bangla and multiline editors.
`KeyboardFieldContextUITests` types through the touch surface and real keyboard
service, compares native Return, and verifies text preservation across fields.
Enable Obadh first through the existing Settings presentation test; use the same
dedicated simulator for subsequent field tests.

```sh
xcodebuild test -scheme ObadhKeyboardUITests -destination 'platform=iOS Simulator,id=<UDID>' -only-testing:ObadhKeyboardUITests/KeyboardFieldContextUITests -parallel-testing-enabled NO -jobs 2 CODE_SIGNING_ALLOWED=NO
```

The custom single-line Return test has a **strict expected failure only on iOS
26.5**: its public proxy newline becomes a space while native Send invokes the
host delegate. Other runtimes must satisfy the normal assertion. Do not count
an expected failure as evidence of native submission parity; see
[KI-005](../KNOWN-ISSUES.md#ki-005) and the
[field-context contract](input-field-context.md). A simulator named iPhone 11
does not qualify A13 latency or physical-device behavior.

## The parity suite (`scripts/parity/`)

Screenshot-measurement verification that the keyboard is geometrically and
chromatically identical to native, across device width classes, host
presentations (modern and legacy), and appearances:

```bash
scripts/parity/run.sh                    # full matrix, PASS/FAIL, exit code
scripts/parity/run.sh "iPhone 17 Pro"    # one device
```

It builds both simulator configs, boots fresh simulators per device class,
captures native and Obadh in the same session, and gates geometry (suggestion
zone, key-row position) and color (key fill, panel, glyphs, strip) against
explicit tolerances. Obadh's cells are self-certified by the probe overlay's
fiducial hairlines; native's are measured by pixel-run analysis. See
[`scripts/parity/README.md`](../scripts/parity/README.md) for the full
contract and its honest limits (simulator runtime only; landscape, iPad, and
pressed-state colors not yet covered).

## Mouse-free simulator automation

Simulator interaction uses XCTest, simctl, and the DEBUG channel without moving
the Mac mouse. `simctl` has no tap primitive; XCTest supplies actual UI gestures.
The pieces are:

- **`ObadhKeyboardUITests`**: enables Obadh through the actual Settings UI.
  Preference writes alone did not register it on fresh iOS 26.5 simulators.
- **`scripts/sim-kbd.py`**: selects an already-enabled Obadh using preference
  hints and relaunch, verifies presentation, takes screenshots, and drives the
  debug channel. Selection failure returns a nonzero exit status.
- **The DEBUG control channel**: a file the extension polls in its own
  sandbox, giving scripted access to the *production* input path:
  `tap:<keys>`, `cursor:<offset>`, `context` (log the document around the
  cursor), `pick:<slot>`, `pickemoji`, `preview:<key>`, `autoinsert:on/off`,
  `probe:on/off`, `glass:<style>`, `mode:<page>`. Input-behavior bugs are
  reproduced and verified end-to-end through the same code a finger would
  hit.

All debug tooling is `#if DEBUG`, verified absent from Release binaries.
