# Keyboard presentation and typography investigation — 2026-09-25

Branch: `fix/keyboard-presentation-lifecycle`, based on `9d9b890`.

## Conclusions

There are **two different presentation problems**:

1. **Verified and mitigated in Obadh:** UIKit presents a temporarily oversized
   extension view. Our phone rows were anchored to its top, so they briefly
   appeared 199–228 points too high. Bottom anchoring keeps the key block steady
   while the root resizes. The requested height and actual ribbon height do not
   change. This removes the large upward jump in the sampled simulator videos;
   it does not control UIKit's container animation.
2. **Reproduced, still unresolved:** UIKit can remove a roughly 17-point margin
   *outside* the extension when switching from system Emoji. The extension's
   bounds, requested height, ribbon, and key positions remain the same. A shorter
   visible suggestion zone therefore does not establish that our ribbon shrank.
   A separate minimal 180-point UIKit keyboard reproduces the same 17-point change,
   excluding Obadh's keyboard code as its cause in this simulator case. No reliable
   public extension API workaround was established. In particular,
   growing our ribbon by 17 points would move the keys and make other paths too tall.

Several independent input/lifecycle defects were reproduced and fixed. Typography
was measured afresh instead of assuming that “system font” means exact native
keyboard parity.

## Environment and evidence quality

- Xcode 26.6 and iOS 26.5 simulator; no OS, Xcode, or runtime upgrades.
- Fresh UI switching captures on an iPhone 17 Pro Max simulator (440 × 956 pt).
- Fresh portrait references at 402 and 440 pt; existing references at 420 pt
  support the width comparison. The fresh 402-point atlas fit independently
  selects 25 pt as well (mean native/Obadh overlap 0.9207).
  These are not iOS 27 measurements.
- The paired phone reports iOS 27.0, build 24A435. It was inspected read-only;
  this branch has not been installed or tested on that phone.
- Repository comments and earlier reports are historical evidence, not Apple API
  contracts. Some comments incorrectly described the outer band as guaranteed.
- Earlier screenshots show the old `94c8132d` build label because direct
  `xcodebuild` does not run `scripts/stamp-build.sh`. The compiler logs and new
  diagnostics establish the tested source; use the stamp script for subsequent builds.
- Local raw artifacts are under `build/keyboard-investigation/` (git-ignored).
  The reproducible tests, analysis scripts, and this report are version controlled.

## 1. Switching glitch: observed frames, then a narrow fix

A fresh trace before the layout fix reads:

```text
root height:       956 → 452 → 253
requested height:  253 throughout
actual ribbon:      34 throughout
viewDidAppear:     at 452; 253 arrives about 34 ms later
```

Another presentation used 481 instead of 452. `viewDidAppear` is therefore not a
reliable “the size has settled” signal. Activating our height constraint earlier
was tried and rejected: the intermediate height and visible resize remained.
Timing improved in one run, but that was not controlled evidence of a fix.

The retained change pins the fixed phone key block to the bottom safe-area edge
and lets the ribbon's *top position* absorb temporary extra root space. It keeps
its fixed height. At the intended root height the constraints produce the original
settled geometry. iPad retains its existing bottom-based layout.

Video evidence, same simulator and real system keyboard menu transitions:

| Measurement | Before bottom anchoring | After bottom anchoring |
|---|---:|---:|
| Settled q-row marker | 662 pt | 662 pt |
| Brief upward positions | 434, 463 pt | None detected |
| Difference from settled | −228, −199 pt | No corresponding jump |

The videos were resampled at 60 Hz; six before-fix samples showed the large upward
positions. The after video also includes the normal keyboard entering from below.
Marker detection leaves obscured frames unclassified, so this is not a claim that
all possible animation artifacts are eliminated. Inspect the recordings as well
as the marker JSON.

Evidence: `before-early-height.log`, `after-bottom-layout.log`,
`switch-{before,after}-bottom-anchor.mp4`, and their `.lines.json` files.
The regression test replays root heights 956, 452, and 253 against the actual
controller and checks the rows' distance from the bottom. It failed before and
passes after. A separate test checks the actual ribbon height across resizing
and reappearance.

## 2. Inconsistent suggestion zone: an independent reproduction

The DEBUG harness historically used `UIKeyboardType.alphabet` (the ASCII-capable
alias), which excluded system Emoji from the switcher. Testing that harness alone
missed the relevant transition. `--keyboard-default` now permits it.

Reproduction on iOS 26.5:

1. Launch the harness with `--keyboard-default --accessory=44 --seed=hello `.
2. Select English (US), then Obadh using the system globe menu; capture.
3. Select system Emoji, then Obadh; capture again.

| Quantity, in points | From English | From system Emoji |
|---|---:|---:|
| Host-reported keyboard height, including accessory | 389 | 372 |
| Outer visible keyboard top | 611.3 | 628.3 |
| Extension view top | 628 | 628 |
| q-row marker | 662 | 662 |
| Actual Obadh ribbon | 34 | 34 |
| Visible suggestion zone | 50.7 | 33.7 |

Both extension traces include 956 → 481 → 253. This directly refutes using those
intermediate heights to detect whether the margin is present. The host observes
the missing 17 points; the extension does not. `HostKeyboardGeometryRecorder`
records frame notifications and `keyboardLayoutGuide` geometry in the DEBUG host.
The extension log now distinguishes requested and actual ribbon heights.

The UI test asserts stable keys and preserved text. It also checks the host height
with an explicitly documented **expected failure** for the system margin defect.
A green test run with that expected failure is **not** a fix for the missing margin.

Evidence: `ui-after-attachments/`, `ui-after-geometry.json`, and
`after-bottom-layout.log` at 10:09:47 versus 10:09:57. The generic screenshot
geometry detector can mistake an accessory bar for native keyboard keys; do not
use its `native-accessory-true` result as a native key-height measurement.

### Minimal independent keyboard control

The separate `ObadhMarginProbe` project replaces the extension with a 180-point
pink UIKit view and one button. It includes **none** of Obadh's engine, theme,
suggestion bar, touch routing, or presentation classifier. The same host test
reports **316 points after English, 299 after Emoji**. This isolates the same
17-point discrepancy from Obadh's keyboard implementation.

The source is `Tests/KeyboardMarginProbe/MinimalKeyboardViewController.swift` and
is excluded from the normal project. To reproduce on a dedicated simulator:

```sh
python3 scripts/parity/generate-margin-probe.py
xcodebuild test -project build/MarginProbe/ObadhMarginProbe.xcodeproj \
  -scheme ObadhKeyboardUITests -destination 'platform=iOS Simulator,id=<UDID>' \
  -derivedDataPath build/MarginProbeDerivedData -parallel-testing-enabled NO \
  -jobs 2 CODE_SIGNING_ALLOWED=NO \
  -only-testing:ObadhKeyboardUITests/KeyboardPresentationUITests/testSwitchingFromSystemEmojiWithAccessory
```

Enable Obadh first using the normal activation test. This experimental project
uses the same simulator bundle IDs, so it temporarily replaces that simulator's
Obadh. Reinstall the normal build afterwards. It is not part of the shipping app.
This is suitable as a small control case for an Apple feedback report; no report
was sent automatically.

### Online reports, independently checked

- [FB24460699 / 17-point margin after foregrounding](https://developer.apple.com/forums/thread/843093):
  a developer reports unchanged extension geometry but a 17-point host-frame
  change on iOS 27, including build 24A435. A reply describes the English/Emoji
  accessory-view path as FB21449121 on iOS 26. These are developer observations,
  not an Apple staff confirmation. Our independent Emoji-path reproduction makes
  this a strong match; it does not prove the user's exact iOS 27 cold-start path.
- [Native-to-custom duplicate/tall-then-small transition](https://developer.apple.com/forums/thread/845726):
  a separate developer reports this on iOS 26.6.2. No verified workaround or Apple
  response was present when checked. Our trace/video provides independent evidence
  of the related oversized-root behavior.
- [iOS 26 extension margins discussion](https://developer.apple.com/forums/thread/800838)
  provides historical context. The older repo attribution to private FB17978212
  could not be independently checked.
- [Current iOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)
  did not identify a fix for this extension-margin problem. The current Apple
  documentation JSON was checked because a search result still returned beta notes.
  Absence from release notes is not evidence that a bug is fixed or absent.

### What the official APIs actually promise

Apple documents [custom keyboard layout](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface)
and [self-sizing input views](https://developer.apple.com/documentation/uikit/uiinputview/allowsselfsizing).
Those support requesting our content height. They do not promise a fixed outer
margin or a single layout pass before presentation.
[systemLayoutSizeFitting](https://developer.apple.com/documentation/uikit/uiview/systemlayoutsizefitting(_:))
computes a fitting size; it does not itself set the frame.
The [keyboard layout guide](https://developer.apple.com/documentation/uikit/adjusting-your-layout-with-keyboard-layout-guide)
is useful in our test *host*, but an extension cannot inspect arbitrary third-party
host views. No private view traversal or guessed OS delay is introduced as a fix.

## 3. Additional verified defects fixed

| Defect | Verification before fixing | Change |
|---|---|---|
| Held delete continues after dismissal | Actual emoji-panel repeat remained active after `viewWillDisappear` | End repeat and cancel touch/preview work on disappearance |
| Discarded repeat controller leaks a live timer | A weak reference stayed alive after its owner released it | Weak timer target plus invalidation on deinitialization |
| Held delete survives row replacement | Start backspace, rebuild number rows; repeat remained active | Cancel the gesture and repeat before rebuilding |
| Old touch release types into new rows | Begin a real `UITouch`, rebuild rows, end it; composer received `a` | Touch surface now clears its tracked touch, not just controller highlighting |
| Old async suggestions remain valid after context reset | Pending work not cancelled, generation unchanged, old ribbon still populated | Invalidate generation, cancel pending query, clear cursor/OOV/ribbon bookkeeping |
| Prior word's emoji survives cursor/document reset | Compose `bhalobasa`, space, change selection; carried emoji remained | Clear carried emoji with composition bookkeeping |
| Caps lock affects only the first letter | Two letters produced `Ab`, not `AB` | Preserve shift while caps lock is active; propagate caps state during appearance updates |
| Accessible keys are disabled and activation does not type | XCTest hierarchy reported disabled buttons; direct accessibility activation failed | Enable semantic keys, label commands, set keyboard-key traits, route activation through normal press/release handling |

The accessibility fix follows Apple's
[keyboard-key trait](https://developer.apple.com/documentation/uikit/uiaccessibilitytraits/keyboardkey)
and [accessibility activation API](https://developer.apple.com/documentation/objectivec/nsobject-swift.class/accessibilityactivate()).
The custom overlay still owns finger input; UI tests check that taps continue to
change the host text. Full VoiceOver typing-mode ergonomics on physical devices
remain a manual verification item.

## 4. Font audit: family, size, weight

Obadh uses `UIFont.systemFont(..., weight: .regular)`. On this runtime it resolves
to `.SFUI-Regular` / `.AppleSystemUIFont`; Bengali fallback resolves to
`.SFBangla-Regular`. These names are diagnostic output, not names the app requests.
Apple's [Typography HIG](https://developer.apple.com/design/human-interface-guidelines/typography)
and [default system design](https://developer.apple.com/documentation/uikit/uifontdescriptor/systemdesign/default)
describe the system fonts, but do not expose the native keyboard's full font recipe.

Measured iPhone portrait adjustments, limited to modern presentation on iOS 26+:

| Role | Before | Now | Evidence |
|---|---|---|---|
| Letters | 23 pt × width scale | 25 pt, regular | Best supported UIKit atlas match across 402/420/440 pt native references |
| Suggestions | 15 pt | 17 pt, regular | Native `I`, `my`, `there` match a UIKit 17-point atlas |
| `123` mode label | 17 pt × width scale | 18 pt, regular | Native ink ~13.3 pt high; system candidate near 18 pt improves fit |

The fresh 440-point screenshot comparison improves mean home-row glyph overlap
from **0.775 to 0.9205**, with translation only, no resizing. For example native
`d` is 18 pt tall; Obadh changed from about 16.7 to 18 pt. Residual shape/width
differences remain, especially `j`. Local runtime-font raster experiments also
suggested a compact-family candidate, but neither that nor a screenshot establishes
Apple's private font identity. No private font names or copied Apple font files
are shipped. An attempted unavailable named font even silently resolved to Times
New Roman, illustrating why name-based guesses are unsafe.

iPad, landscape, older OS, legacy-host typography, command symbols, and Bengali
shaping are not claimed to have newly established exact parity. Those require
their own role/script/reference measurements. Their existing metrics are preserved.

Evidence: `font-atlas-before.json`, `font-after.json`, `word-fit.json`, UIKit atlas
under `build/font-audit/`, and `scripts/parity/phone-type.py`. The mode-label analysis includes the entire key; an initial partial crop was
rejected and corrected before selecting its size.

## Verification and reproduction

```sh
scripts/stamp-build.sh
xcodegen generate
swift test --jobs 2
xcodebuild test -scheme ObadhKeyboardLifecycleTests \
  -destination 'platform=iOS Simulator,id=<UDID>' -jobs 2 CODE_SIGNING_ALLOWED=NO
xcodebuild test -scheme ObadhKeyboardUITests \
  -destination 'platform=iOS Simulator,id=<UDID>' -parallel-testing-enabled NO \
  -jobs 2 CODE_SIGNING_ALLOWED=NO
```

Use a dedicated simulator: the UI activation test opens Settings and enables
Obadh. It does not require the Mac mouse. The UI suite covers genuine globe-menu
switching, foregrounding, accessory views, system Emoji, landscape, and finger
input. A changed height discrepancy outside the known 17-point case fails normally;
the expected-failure annotation does not suppress arbitrary sizing regressions.
The lifecycle bundle compiles the real controller/views and engine; it is
not a mock of the sizing or suggestion implementation.

The screenshot harness had another verified defect: writing `AppleKeyboards`
did not enable the extension in `UITextInputMode.activeInputModes` on a fresh
simulator. An initial run captured native in both slots and correctly ended
**INCOMPLETE**, not PASS. The sweep now uses Settings UI activation and aborts
when Obadh selection is not confirmed. A subsequent run exposed detached DEBUG
controllers stealing probe commands (logged `win 0×0` while the visible keyboard
had no probe). The channel now checks that its handler is attached, and detached
frame monitors stop polling. A before/after test verifies that an inactive handler
leaves the command for the active one. Native reference capture explicitly selects
`en-US` instead of assuming the next input mode is English.

For font matching, run the lifecycle scheme with `OBADH_FONT_ATLAS=1` as a build
setting, then pass `--atlas-dir build/font-audit/atlas` to `phone-type.py`.
For transition evidence, record with `simctl io ... recordVideo`, stop that recorder
with SIGINT, then run `transition-lines.py VIDEO --width 440 --height 956`.

## Recorded verification results

| Check | Result |
|---|---|
| SwiftPM core | 136 passed |
| Real Swift/C engine integration | 17 passed |
| UIKit lifecycle, timers, debug routing, font diagnostics | 15 passed (font atlas export is opt-in) |
| Real UI scenarios | Settings activation, repeated switching/foregrounding, landscape and system Emoji exercised; the known 17-point discrepancy is an expected failure |
| Minimal independent keyboard | Same expected 17-point failure: 316 → 299 |
| Fresh portrait screenshot matrix | **48/48 checks passed**: 402/440 pt × modern/legacy × light/dark |
| Release simulator build | Passed; new host/probe diagnostic markers absent from app and extension binaries |
| Whitespace / Python / shell checks | Passed |

The final screenshot artifacts are in `build/parity/20260925-102621/`.
`build/parity/20260925-101626/` is the earlier run with two missing-probe detection
failures and must not be reported as passing. The transition videos establish a
mitigation for the key jump, not a guarantee about every UIKit animation frame.
No iOS 27 physical-device validation or complete iPad/landscape pixel sweep was
performed in this investigation.

## Remaining device verification

Install this branch's DEBUG build on the iOS 27 phone when a device session is
available; no macOS upgrade is needed for the investigation tooling itself.
Capture the probe and sizing log for cold host launch, English → Obadh, Emoji →
Obadh, focused Home → return, light/dark, and a host with an accessory/composer.
Compare the extension ribbon separately from the outer margin. Check fast typing,
held delete while switching, caps lock, emoji search, and VoiceOver activation.

The user-visible missing outer margin remains open. The branch fixes verified
Obadh defects and improves evidence collection; it should not be described as
an exhaustive proof of native parity or an iOS 27 margin fix.
