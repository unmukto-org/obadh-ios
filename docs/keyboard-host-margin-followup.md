# Host margin and native materials follow-up — 2026-09-25

Branch: `fix/keyboard-host-top-margin`, based on `8ab0abca`.

## Status

The 17-point margin discrepancy is **still unresolved**. Further public-API
experiments reproduced it; none is included in the production keyboard. This is
not evidence that every possible workaround is impossible.

A separate, verified accessibility appearance defect is fixed: native keys become
more distinct with Increase Contrast / Reduce Transparency, but Obadh's overlays
previously kept their default opacity. Key overlays now follow those preferences,
including changes after attachment. Press feedback respects Reduce Motion. The
onboarding primary action adopts SwiftUI's native `glassProminent` button style on
iOS 26+, with the existing style retained on earlier systems.

## Margin experiments

All simulator measurements below use the same dedicated iOS 26.5 iPhone 17 Pro
Max, the real system globe menu, and a host with a 44-point input accessory view.
The extension contains only a pink input view and one button. The engine,
suggestions, theme, classifier and Obadh touch routing are excluded.

| Input-view strategy | Host height after English | After Emoji | Difference |
|---|---:|---:|---:|
| Default inherited root, constrained to 180 (prior control) | 316 | 299 | 17 |
| Explicit `.keyboard` root, constrained to 180 | 316 | 299 | 17 |
| Explicit `.default` root, constrained to 180 | 316 | 299 | 17 |
| `allowsSelfSizing = false`, retaining the 180 constraint | 316 | 299 | 17 |
| 180 → 197 → 180 height pulse after appearance | 316 | 299 | 17 |
| Intrinsic height + `sizeThatFits`, no height constraint | 360 | 343 | 17 |
| Entirely system-selected sizing, no height constraint | 360 | 343 | 17 |
| Explicit `systemLayoutSizeFitting` overrides returning 180 | 316 | 299 | 17 |
| Replace the input-view shell after appearance | 316 | 299 | 17 |

The intrinsic-size experiment did not obtain the requested 180-point content
height. The explicit fitting override did, but neither stabilized the margin.
This distinguishes an ineffective sizing request from a correctly applied size
that still exhibits the host defect. Apple's documentation specifies
[`systemLayoutSizeFitting`](https://developer.apple.com/documentation/uikit/uiinputview/allowsselfsizing)
for self-sizing input views, so that documented path was tested explicitly.

The larger pulse excludes the possibility that the earlier one-physical-pixel
experiment merely rounded away **in this simulator reproduction**. A separate
physical-device experiment issued 255 → 272 → 255 through the existing DEBUG
command channel while Messenger remained foregrounded. The after screenshot
looked taller, but the helper's completion record showed `firstConsumed=true`
and **`resetConsumed=false`**. Thus the apparent recovery is not a fix: the
temporary larger request had not been cleared. The screenshot alone was misleading.
A repeat with explicit phase logging was blocked by the phone locking; it was
cancelled. The identified Obadh keyboard extension process was then terminated
to discard its instance-only height override. No persisted layout preference was
changed. The earlier 0.333-point device experiment remains documented separately.

Reproduce individual variants:

```sh
python3 scripts/parity/generate-margin-probe.py --variant fitting
xcodebuild test -project build/MarginProbe/ObadhMarginProbe.xcodeproj \
  -scheme ObadhKeyboardUITests \
  -destination 'platform=iOS Simulator,id=<dedicated simulator UDID>' \
  -derivedDataPath build/MarginProbeDerivedData \
  -parallel-testing-enabled NO -jobs 2 CODE_SIGNING_ALLOWED=NO \
  -only-testing:ObadhKeyboardUITests/KeyboardPresentationUITests/testSwitchingFromSystemEmojiWithAccessory
```

Use `--help` for the other variants. `inherited` is the unchanged baseline.
**This project replaces Obadh in that simulator. Do not install it on a user's
phone.** Reinstall the normal app afterwards. The test prints
`MARGIN-COMPARISON english=… emoji=…`; its explicitly expected 17-point assertion
failure is evidence of the remaining bug, not a successful margin fix.

The production code's old comment attributing 290/314-point grants to system
sizing was corrected: another existing code comment correctly identified those
values as an earlier metrics feedback loop. Neither historical explanation was
used as a substitute for the fresh minimal tests above.

### Why automatic compensation is not included

The known shorter and normal presentations can have identical extension bounds,
safe areas, window geometry and height traces. Adding 17 points without a reliable
signal recreates the taller-ribbon regression. Forcing an input-mode change or
changing the host's text-field traits would interfere with the user's typing
context. `reloadInputViews()` applies to the owning first responder; our extension
does not own Messenger's text view. See [Apple's contract](https://developer.apple.com/documentation/uikit/uiresponder/reloadinputviews()).

The [matching developer report](https://developer.apple.com/forums/thread/843093)
was rechecked. It remains a community report, including an iOS 27 build 24A435
observation, without an Apple-confirmed workaround. Our independent tests support
the diagnosis for the tested path; they do not make the forum an API guarantee.

## Liquid Glass: test native behavior before choosing a material

Apple says that adopted Liquid Glass components receive the system's appearance
customization automatically ([WWDC26 keynote](https://developer.apple.com/videos/play/wwdc2026/101/)).
Apple also specifically advises against stacking glass on glass; thin fills and
vibrancy belong on the upper layer ([Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)).
The [materials guidance](https://developer.apple.com/design/human-interface-guidelines/materials)
and [adoption guide](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
require checking custom colors and animation against accessibility preferences.

We tried enabling untinted `UIGlassEffect(.regular)` on every key. Switching and
typing tests passed, but the actual appearance regressed: dark key faces became
roughly RGB 32 by default and 20–21 with accessibility settings, against native
78–79 and 128–129 respectively. That experiment was rejected. Its passing tests
were not treated as proof of visual parity.

The retained arrangement is the public
[`UIInputView(inputViewStyle: .keyboard)`](https://developer.apple.com/documentation/uikit/uiinputview)
background, with thin key overlays. The backdrop tracks the native keyboard's
material; settings/navigation use standard controls, and the onboarding primary
button now uses the native glass button style. There is no private preferences
lookup or independent app-level Liquid Glass selector.

### Verified key-overlay defect and fix

Same screen, neutral gray host, sampled away from glyphs, dark appearance:

| System setting | Native key RGB | Before fix | After fix |
|---|---|---|---|
| Default | 78 / 78 / 79 | 78 / 78 / 79 | 78 / 78 / 79 |
| Reduce Transparency | about 129 / 129 / 129 | 103 / 103 / 103 | 127 / 127 / 127 |
| Increase Contrast | about 129 / 129 / 129 | 103 / 103 / 103 | 127 / 127 / 127 |

The difference from native is reduced from about 26 levels to about 2 in these
samples. This is measured parity for these cases, not a claim that Apple's
private keyboard palette is a public contract.

The stronger overlay uses the already measured accessible/legacy palette:
white alpha 0.30 in dark appearance, opaque white in light. The native backdrop
becomes opaque under Reduce Transparency, so content does not show through.
Buttons observe `UITraitAccessibilityContrast` and the documented
[`reduceTransparencyStatusDidChangeNotification`](https://developer.apple.com/documentation/uikit/uiaccessibility/reducetransparencystatusdidchangenotification).
The trait regression checks both activation and reversal without a controller
refresh, including the pressed fill.

### Validation and limits

- 19 UIKit tests pass, including the new inherited-contrast regression.
- The pre-fix regression failed the high-contrast resting and pressed alpha checks.
  Its first run also had an unrelated fixture error (using the controller's stale
  traits immediately after overriding its view); that assertion is not evidence
  of a production bug. The fixture now settles inheritance and uses the view's traits.
- Real simulator Settings toggles were exercised in light and dark appearance;
  screenshots compare native and Obadh, typing still works, and the original
  accessibility preferences are restored. Light accessible key faces are exactly
  white in both keyboards. The initial light run encountered an ignored Settings
  tap during foregrounding; the test now checks state before a single retry.
- The Release onboarding screen was rendered and visually checked on the simulator.
- Release build succeeds with the shipping configuration.
- The simulator Settings app did not expose Display & Brightness during inspection.
  Clear/Tinted and the iOS 27 Liquid Glass slider still require a physical-device
  check. Do not equate the accessibility tests with verification of that slider.
- The physical-device refresh trial is inconclusive as explained above. A fully
  completed repeat and the iOS 27 glass slider check require the phone to remain
  unlocked. Build 1.0 (108) was retained throughout the margin experiments.

Local evidence is in `build/host-margin-investigation/`. Test logs use
`/tmp/obadh-margin-*.log`, `/tmp/obadh-native-material-*.log`, and
`/tmp/obadh-contrast-baseline.log`. These capture geometry and the test harness;
no conversation text is needed for this report.

## Installed verified appearance changes

After simulator verification, build **1.0 (109), code revision `1780584a`** was
installed on the iPhone 16 Pro Max. CoreDevice independently reports installed
bundle version 109; app and extension carry the same revision and build number.
It contains the accessibility/material changes and **no margin workaround**.
The diagnostic keyboard instance was terminated and both temporary diagnostic
apps were removed. The dedicated simulator was restored to the normal Debug
keyboard and shut down. Physical checks of the iOS 27 slider remain pending.

The installed app subsequently launched successfully. A physical Settings
inspection did not locate the expected Liquid Glass row; its follow-up was
blocked by another device lock before it could capture the actual controls.
This is an incomplete inspection, not evidence that the setting is unsupported.
No phone appearance preference was changed. Queued tests were stopped and the
temporary runner removed again; an uninterrupted unlocked-device session is
needed to complete those checks.

## Completed iOS 27 physical-device follow-up

Follow-up branch: `test/ios27-device-validation`, retaining installed build 109.

### Liquid Glass slider

Apple's current [iPhone guide](https://support.apple.com/en-mt/guide/iphone/iphd6804774e/ios)
places the slider under **Settings → Appearance → Liquid Glass**. The earlier
Display & Brightness route was outdated for this device. The actual accessibility
hierarchy confirms an enabled “Tint Amount” slider. Its original value was 90%.

A completed physical test independently verified **0% and 100%**, captured native
English and Obadh on the same neutral gray host at each setting, checked the
seed text remained unchanged while switching, and verified an Obadh key still
entered text in the local test field. It then restored and asserted **90%**,
with a final Settings screenshot. No text was entered into Messenger.

| iOS 27 tint | Native key RGB | Obadh key RGB | Native/Obadh background RGB |
|---|---|---|---|
| 0% | 77 / 77 / 77 | 77 / 77 / 77 | 43 / 43 / 43 |
| 100% | 77 / 77 / 77 | 77 / 77 / 77 | 43 / 43 / 43 |

Samples are medians from the q key's upper-left interior and adjacent gap, away
from glyphs. In this dark, neutral-host test **neither native keyboard nor Obadh
changes those colors with the slider**. Matching this behavior is preferable to
adding an artificial tint response. This is verification of these keyboard
surfaces on this phone, not proof of every Liquid Glass component or backdrop.

The initial automation attempts failed: Xcode's normalized slider API often
reported a different final value than requested, and short drags produced
inconsistent results. Those attempts are not successful comparisons. A slow
drag starting at the measured thumb center, allowing its press animation to
settle, established the requested endpoints and restored the recorded original.
Some failed attempts temporarily left another value; the completed run's final
90% assertion and screenshot establish the final state.

### Fully completed height refresh

The physical test used the installed keyboard in Obadh's DEBUG host with a
44-point accessory, selecting Emoji then Obadh. The helper recorded:

- 20.99 s: request 272 points.
- 22.04 s: first request consumed.
- 22.05 s: request automatic sizing again (`ask:0`).
- 23.09 s: reset consumed.

The final screenshot was taken after both commands. The outer keyboard top
remained **626.67 points** before and after; the q key remained at **662 points**.
The missing band did not return. The before/after crops are 99.66% pixel-identical;
the visible difference is the expected spacebar introduction changing to its
small language caption. This rejects the 17-point height pulse for this physical
reproduction as well as the earlier simulator reproduction.

One preceding attempt lost its host accessibility connection and consumed neither
command. It is excluded. The successful repeat kept the local test host active
by tapping its inert build label during the wait. No Obadh-named crash report was
found in the device crash-log listing; that alone does not explain the connection
loss. The Messenger-specific repeat initially stopped because no conversation
composer was open; it remains separate from the completed local-host experiment.

Evidence: `build/host-margin-investigation/device-verified-glass-and-pulse/`
contains the exported XCTest manifest, original captures, comparison sheets, and
`pulse-geometry.json`. The helper's full phase report is
`device-pulse17-local-completed-result.txt`; the completed two-test log is
`logs/obadh-device-glass-and-pulse-final2.log`. Both XCTest methods passed.

## Additional verified typography correction

Branch: `fix/phone-letter-case-typography`. Case-specific captures revealed a
defect missed by the earlier lowercase font audit: native capitals are smaller
than lowercase letters, while Obadh used 25 points for both. The same measurements
were independently reproduced on the iOS 26.5 simulator and iOS 27 phone.

For the W/w key, measured relative to the key face (3× captures, identical ink
threshold for native and Obadh):

| Quantity | Native | Obadh before |
|---|---:|---:|
| Lowercase w height | 12.67 pt | 12.67 pt |
| Lowercase baseline/ink bottom | 28.67 pt | 31.00 pt |
| Capital W height | 15.33 pt | 17.67 pt |
| Capital W width | 18.33 pt | 21.67 pt |

The correction retains the public regular system font, uses 21.5-point capitals
and 25-point lowercase, and adjusts their baselines separately. A UIKit-rendered
atlas and actual button captures support the smaller capital size; residual
subpixel shape differences do not establish Apple's private font recipe. These
metrics apply only to the already measured modern portrait iPhone path. Other
layouts retain their previous values. Key frames and hit areas are unaffected.

The first corrected simulator capture matches the lowercase w dimensions and
baseline exactly relative to its key, and reduces capital W size to 18.67 × 15.00
points. The final uppercase baseline is raised one additional physical pixel
relative to that capture. The complete 19-test UIKit suite and device Release
build pass. Build **1.0 (112), revision `a0abe326`**, was then installed and
launched on the iPhone 16 Pro Max. The completed physical case-capture test
confirms both lowercase and uppercase ink bottoms at 28.67 points relative to
the key face, matching native. Capital W measures 18.67 × 15.00 points versus
native 18.33 × 15.33. Lowercase w dimensions also match the native sample.

The diagnostic UI test now waits for the globe menu to dismiss and asserts the
expected lowercase/uppercase keys exist before capturing. Its first naive run
captured the still-open keyboard menu for Obadh; those captures were rejected.
Evidence is in `letter-alignment-verified-before/`, `letter-alignment-after/`, and
`device-letter-cases-before/` under the investigation artifact directory.

The 17-point host-margin investigation remains the priority and is continuing.
These typography changes are independent of a height workaround.


## Continued sizing-contract experiments

Branch: `fix/keyboard-host-margin-contract`. These variants remain confined to
the simulator-only minimal probe; build 112 on the phone contains none of them.

| Additional strategy | Host height after English | After Emoji |
|---|---:|---:|
| Refresh primary language (`en-US` → `bn-BD`) after appearance | 316 | 299 |
| Controller `preferredContentSize = 180`, without height constraint | 360 | 343 |
| Required (1000) content-height constraint | 316 | 299 |
| Temporarily set `hasDictationKey = true`, then restore false | 316 | 299 |

The documented dictation-key setter changes the system dictation-button contract;
reapplying it did not invalidate the stale margin in this reproduction. All four
experiments retain the 17-point difference. The expected-failure UI test reporting
success does **not** mean these approaches fixed the height.

Additional public geometry observations also match in normal and short states:
the root and window are 440 × 180, `keyboardLayoutGuide.layoutFrame` is
(0, 180, 440, 0), and both accessibility screen conversion and accessibility frame
report (0, 0, 440, 180). These values do not provide a reliable compensation signal.

Logs: `/tmp/obadh-margin-language-refresh.log`,
`/tmp/obadh-margin-preferred-only.log`, `/tmp/obadh-margin-required.log`,
`/tmp/obadh-margin-observe.log`, `/tmp/obadh-margin-observation-values.log`, and
`/tmp/obadh-margin-dictation-refresh.log`.


### Trace of the simulator's host calculation

A debugger inspection of the loaded iOS 26.5 UIKit binary identified the
rounded-keyboard extra-padding calculation: it returns `24 - keyplanePadding.top`
when that top padding is nonzero, otherwise zero. The accessory alignment code
calls that calculation. This is implementation evidence for this runtime,
**not a public API contract or a verified iOS 27 implementation detail**.

A separate simulator-only observer then read the already existing layout in our
own test host while the original switching test ran:

| Settled state | Retained native keyplane top | Additional padding | Host height |
|---|---:|---:|---:|
| Native English | 7 | 17 | 389 |
| Minimal Obadh after English | 7 | 17 | 316 |
| Native Emoji | 0 | 0 | 443 |
| Minimal Obadh after Emoji | 0 | 0 | 299 |

The retained native layout state changes the extra padding while Obadh's content
request remains 180. This explains the exact 17-point discrepancy in the
simulator reproduction, and provides a more specific mechanism than an
unspecified sizing race. The observer does not change the layout or read text.
`HostMarginTrace.m` is included only by the generated `host-trace` variant and has
a compile-time error for physical-device builds. It uses runtime inspection for
research and must never enter the shipping targets.

Additional public-API probes:

- Input-mode notifications and lifecycle observations: `documentInputMode` is nil
  and the responder mode is `bn-BD` after both English and Emoji; no reliable
  previous-keyboard signal was exposed.
- Same-orientation scene geometry request: iOS rejects it because the keyboard's
  windowing mode does not permit programmatic orientation changes.
- Zero-distance cursor request: the host remains 316 versus 299 points.
- Reapply the unchanged keyboard type: the proxy does not implement the optional
  public setter (`responds(to:) == false`), so nothing was assigned. Initial Swift
  attempts to call that optional protocol setter did not compile; these are not
  runtime results. The final guarded probe built and ran.

The test's expected height failure had also prevented its later text check from
running because `continueAfterFailure` is false. The expected assertion is now
last, after text preservation and an added foregrounding capture. Previously green
runs establish the geometry comparison, not completion of those skipped checks.

Evidence: `/tmp/obadh-rounded-container-symbols.log`,
`/tmp/obadh-container-inset-calculation.log`,
`/tmp/obadh-margin-host-trace-values.log`, and the `input-mode`,
`geometry-refresh`, `context-refresh`, and `trait-refresh` experiment logs.


The completed foreground trace also verifies the recovery: retained native
keyplane top changes from 0 to 7; extra padding changes from 0 to 17; host height
changes from 299 to 316. The key remains in its original position, and both text
preservation assertions run and pass. The expected 17-point failure occurs last.
Captures were exported and visually inspected in
`build/host-margin-investigation/host-trace-foreground/`. The completed run is
`logs/obadh-margin-host-trace-foreground-completed.log`; matching runtime values
are in `logs/obadh-margin-host-trace-foreground-values.log`. The other experiment
logs above have also been copied into the investigation's `logs/` directory.

A fresh review of [KeyboardKit's current release notes](https://github.com/KeyboardKit/KeyboardKit/blob/main/RELEASE_NOTES.md)
found its own row-height, iPad toolbar and layout-cache corrections, but did not
identify a remedy for this retained native keyplane padding. Those changes are
not evidence that this host-margin issue is solved.


### Final verification of the full keyboard for this investigation pass

The corrected UI test ran against the normal production implementation (Debug
build), after reinstalling it over the minimal probe on the dedicated simulator:
English → Obadh **389 pt**, Emoji → Obadh **372 pt**, then foreground → Obadh
**389 pt**. Key-position and both text-preservation checks passed, including the
new assertion that foregrounding returns to the original host height. The known
17-point assertion still fails as expected. This is a confirmed unresolved
regression, not a fixed-height result. Log: `logs/obadh-production-margin-sequence.log`.

The normal simulator build succeeds. Phone build 112 remains installed; CoreDevice
independently reports bundle version 112. Experimental height changes were not
added to it. The feedback draft is `docs/keyboard-margin-feedback-draft.md` and
has not been submitted. Height remains an open acceptance criterion.

## Native-state refresh investigation

Branch: `investigate/keyboard-native-state-refresh`, based on `dcd5c6f`.
No production keyboard change is included in this pass. Phone build 112 remains
the installed keyboard; diagnostic code is confined to generated test projects.

### Host reload: simulator success does not transfer to iOS 27

A focused `UITextView.reloadInputViews()` in the owning host repairs the iOS 26.5
reproduction. The minimal keyboard changes from 299 to 316 points, and the
retained native keyplane top changes from 0 to 7. A second, independent UIKit
host using the normal Obadh keyboard confirms 372 → 389 points, with both an
insertion point and a selected word. Text, selection and first-responder status
are preserved. That simulator test passes without an expected height failure.

The same independent host on the iPhone 16 Pro Max, iOS 27.0 (24A435), reports
391 after English and 374 after Emoji. Calling `reloadInputViews()` leaves it at
374. Text, selection and focus checks pass; the height assertion correctly fails.
This rules out shipping the simulator result as an iOS 27 solution.

Same-frame `resignFirstResponder()` / `becomeFirstResponder()` inside
`UIView.performWithoutAnimation` repairs the first device sequence, 374 → 391,
but fails the next sequence, 374 → 374. Text, selection, focus and input-mode
language remain unchanged. Repeating with the selected word in a fresh host
repairs 374 → 391; selection alone does not explain the preceding failure.
The refresh is not reliable across these sequences. Neither host operation is
available to a keyboard extension controlling another app's editor.

A further unselected repeat fails the input-mode preservation check:
`text=true selection=true focus=true mode=false`. The screen recording shows
the native English keyboard afterwards (host height 364). It never reaches its
height assertion. This is an additional reason to reject responder re-presentation
as a seamless repair, not a successful margin restoration.

The independent host has its own bundle ID and no extension, app-group access,
or preference writes. It can test the already installed keyboard without replacing
it. Generate it with `python3 scripts/parity/generate-margin-host.py`, then use
the `MarginHostTests` scheme under `build/MarginHost/ObadhMarginHost.xcodeproj`.
Physical tests use `-collect-test-diagnostics never`. The diagnostic tests have
ordinary failing height assertions: a failure is retained as evidence.

### Additional extension-side controls

All completed simulator comparisons below retain **316 → 299 → 316** for
English, Emoji and foregrounding, with unchanged test text:

- Extension metadata `PrimaryLanguage = en-US` (built plist independently read).
- Metadata `IsASCIICapable = false`.
- Set `primaryLanguage = en-US` early in `viewDidLoad`.
- Reload the extension's own responder; public responder traversal finds no
  first responder, and the document proxy does not respond to `reloadInputViews`.
- Empty text insertion in the controlled, unselected test field. This can have
  editing side effects and is not a production workaround.
- Use a plain `UIView` root instead of `UIInputView`.
- Request a supplementary lexicon after appearance.

The iOS 26 `effectiveGeometry.coordinateSpace` is full-screen in both states;
converted screen bounds, layout margins, additional safe areas and public traits
also match. `UIWindowSceneGeometry.systemFrame` is unavailable on iOS, so it
cannot provide a supported compensation signal.

Two experiments need qualifications:

- Requesting height zero then restoring 180 does not actually collapse the
  content: UIKit grants 224 then 180. The final heights still differ by 17.
- Clearing `inputView` and rebuilding asynchronously loses the working test key.
  That trial is rejected for a functional regression, not counted as a completed
  height comparison.

The initial lexicon probe crashed because its callback assumed main-actor
execution while UIKit called it on an XPC reply queue. A `@Sendable` callback
that explicitly hops to `MainActor` fixes the diagnostic; the completed test
still reproduces the margin discrepancy. Production does not call this API.

### Capture reliability

In the standalone physical-host tests, both `app.screenshot()` and
`XCUIScreen.main.screenshot()` include native Emoji/alphabet layers over Obadh
after switching. Time-matched frames from the XCTest recording also show them;
later frames after re-presentation show a single keyboard. An initial comparison
against a later recording frame incorrectly suggested an app-screenshot-only
artifact. That explanation is withdrawn. This is recorded transition evidence;
direct observation of the phone and delayed captures are needed before assigning
the rendering fault to Obadh. Geometry conclusions above use actual keyboard-frame
notifications, independently of images.

An additional completed capture test waits eight seconds after each switch, with
no refresh operation. Both English and Emoji layers are still present in its
delayed screen captures; host heights remain 391 and 374 respectively. This is
not merely a capture taken before the globe menu closes. It reproduces in the
independent diagnostic host. The test passes its text-preservation checks; that
pass is **not** a visual-quality or height-fix assertion. Captures are in
`device-host-settled/`. A direct on-phone observation is still requested before
assuming these captured layers explain the user's momentary color change.
The earlier independent-host simulator capture after Emoji has a single, clean
Obadh keyplane (`simulator-independent-host/`); the recorded overlay is not present
in that control.

Evidence is copied to `build/host-margin-investigation/logs/`, including
`obadh-margin-host-reload-repeated*`, `obadh-margin-independent-host-*`, and
`obadh-margin-host-device-*`. The physical re-presentation recording and original
snapshots are exported in `device-host-representation/` under that directory.

Apple's current [custom-keyboard configuration guide](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface)
still describes changing the extension view's height constraints. Its
[reload contract](https://developer.apple.com/documentation/uikit/uiresponder/reloadinputviews%28%29)
requires the owning object to be first responder. The related SwiftUI keyboard
toolbar discussion concerns a host-owned toolbar; its overlay / `safeAreaBar`
suggestions do not grant an extension control over Messenger's input accessory.
The matching 17-point forum report remains community evidence, not an
Apple-confirmed extension workaround.

The final independent-host test targets compile with `build-for-testing` after
improving failure reporting to capture the actual preservation status before
asserting it. Generator syntax checks and `git diff --check` pass. These are
diagnostic validation results, not a production fix. Both temporary host apps
and runners were removed from the phone and dedicated simulator. The normal
Obadh simulator app was restored, and that simulator was shut down. Phone build
112 and system appearance preferences are retained. No Messenger text was touched.
