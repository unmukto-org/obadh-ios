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
