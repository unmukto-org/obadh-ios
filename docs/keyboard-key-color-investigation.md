# Key-color flash after switching keyboards

Follow-up to [the presentation investigation](keyboard-investigation.md),
2026-09-25. Branch: `fix/keyboard-switch-key-colors`, based on `d9377058`.

## Confirmed application bug

`reloadKeyboardRows()` constructs and styles each button **before** adding it
to the keyboard hierarchy. `updateAppearance(traitCollection:)` used the
controller's supplied traits for text but ignored those traits for the fill:
`applyPressedState` read the detached button's own `traitCollection` instead.

In the UIKit regression test, a key configured for dark appearance received a
white fill with alpha **0.87**, although the correct dark fill is **0.16**.
This occurred for letter, space, and delete keys. These are fill opacities, not
measured screen brightness; the visible result also depends on the backdrop.

The key also had no trait-change handler to update its fill after attachment.
A separate test with a real `UIWindow` verified that inherited traits changed
to dark while the old light fill remained. Pressing/releasing the key corrected
it because that path reread its now-current traits. Changing back to light
again left the stale dark fill until another refresh. The baseline had five
failing fill assertions across these two tests.

The controller's `viewDidAppear` language intro calls `refreshKeyboard`, which
can subsequently correct attached buttons. That supplies a code path for a
brief incorrect fill followed by recovery. It does **not** prove the exact
timing or cause of every flash reported on the physical iOS 27 device.

## Fix

- Use the same supplied traits for initial key text and fill.
- Observe inherited interface-style changes on the key itself and update its
  fill without waiting for another controller refresh or touch.

The palette, opacity values, glass configuration, and keyboard geometry are
unchanged. The final UIKit suite passes 18 tests, including all three new
appearance tests and the existing lifecycle, input, timer, and typography tests.

## Other candidates, not established causes

The default keys are flat translucent fills over a `UIInputView(.keyboard)`
backdrop, inside a `UIGlassContainerEffect` on iOS 26+. The default does not
create a `UIGlassEffect` for each key. A transient change to the system's
backdrop could therefore change visible key colors even with an unchanged
fill. No backdrop removal or opaque-color workaround is justified yet.

Inspection of the prior light-mode switching video did not show a comparable
fill flash in the sampled transition. A label-free space-key patch remained
RGB 245/245/245 through its language-label fade. This limited negative result
does not cover dark mode, other switch timings, or physical-device compositing.

## Sources checked against runtime evidence

- [Apple: Unleash the UIKit trait system](https://developer.apple.com/videos/play/wwdc2023/10057/)
  explains that detached views do not have current inherited traits and that
  trait updates occur before layout. The detached-key and window tests above
  independently exercise the relevant behavior.
- [Apple: viewIsAppearing](https://developer.apple.com/documentation/uikit/uiviewcontroller/viewisappearing(_:))
  describes when the controller and view have current traits during presentation.
- [Apple: UIVisualEffectView](https://developer.apple.com/documentation/uikit/uivisualeffectview)
  documents how ancestor opacity and snapshots can affect visual effects.
  This establishes another possible mechanism, not proof it caused this report.
- [Developer report: custom-keyboard switching overlay](https://developer.apple.com/forums/thread/845726)
  describes a faint overlay / tall-then-shrink transition on iOS 26.6.2.
  It is a developer observation, without an Apple confirmation, and does not
  establish the cause of Obadh's color change.

## New report: sometimes taller correction ribbon on the installed build

The baseline phone build was Debug 1.0 (107), revision `d9377058`. The user
identified Facebook Messenger as a frequent host and also observed the short
ribbon during simulator testing. A passing key-position test does not clear
these visible-zone failures.

An older note claimed iOS 27 removed legacy compatibility universally. This was
incorrect: [Apple's framework engineer clarified](https://developer.apple.com/forums/thread/838637)
that Xcode 26 builds can retain compatibility mode on iOS 27. The existing
iOS 26 geometry classifier still must not be enabled on iOS 27 without device
measurements. Messenger's current presentation cannot be established by its name.

### Taller ribbon: diagnostic override confirmed on the phone

Direct `devicectl` access to the App Group failed; the app's diagnostic mirror
was initially absent. A separately signed XCTest runner opened the **installed**
app's Sizing Log screen, creating `Documents/obadh-sizing.jsonl`; no Obadh app
replacement was needed. The exported 33 records establish:

| Mode | Presentations | Requested root | Requested / actual ribbon |
| --- | ---: | ---: | ---: |
| Auto | 26 | 255 pt | 36 / 36 pt |
| Pinned Band-less | 7 | 273 pt | 54 / 54 pt |

The experimental override was active from record #27 onward. It explicitly
adds 18 points to the ribbon. With the OS top band also present, it produces
the excessively tall visible zone. Restoring Auto through the installed app
produced a new device record with root 255 and ribbon 36 again.

Fix: normal DEBUG launches now restore Auto and omit the experimental
presentation selector. Deliberate sizing experiments require the launch
argument `--experimental-sizing`; their UI explains that they can distort
the ribbon. A UI test selects Band-less, relaunches normally, verifies that
the controls are absent, then reopens experimental mode to verify that the
stored choice has returned to Auto. It passes. The log viewer now displays
the recorded **actual** ribbon height as well as its requested value.

### Short ribbon: independently reproduced in Messenger on iOS 27

The standalone runner then captured cropped keyboard screenshots on the
iPhone 16 Pro Max, iOS 27.0 (24A435), while the baseline Obadh build stayed
installed. It changed keyboard selections and foreground state without typing
or sending messages. Messenger's captured keyboard uses modern rounded framing.

| Incoming path | Outer top margin / visible suggestion zone |
| --- | --- |
| Native English → Obadh, Auto | Normal |
| Native Emoji → Obadh, Auto | Outer top moves down about 17 pt; zone becomes shorter |
| Return to Messenger from Home | Normal margin restored |

The key-row pixels stay at the same screen height across the Obadh captures.
The short state therefore is not fixed by the color change or resetting the
diagnostic override. These physical-device observations agree with the earlier
minimal-keyboard simulator experiment and the independent developer report
[FB24460699 / FB21449121](https://developer.apple.com/forums/thread/843093).
They do not establish that every possible short-ribbon case shares that cause.

The iOS 26.5 modern and compatibility host switching/foregrounding tests pass
for key positions and typing, with and without a 44-point input accessory.
The compatibility-host Emoji comparison also ran; the test's explicit
expected-failure treatment for the known 17-point OS margin remains in effect.
None of these key-position passes is a full ribbon-parity pass.

Device attachments and baseline sizing export are under
`build/key-color-investigation/messenger-device/` and
`build/key-color-investigation/iphone-sizing-mirror.jsonl`.

### Rejected refresh experiment

A temporary, separately signed helper app with the existing development App
Group entitlement sent the baseline keyboard's DEBUG commands while Messenger
remained foregrounded. After Emoji → Obadh, it requested 255.333333 points and
then restored `ask:0` (the normal computed height). Both command files were
consumed; the helper recorded that confirmation in its own Documents folder.
The before/after device screenshots retain the short top margin. This small
height pulse did not repair the observed issue, so it is not part of the fix.
The helper and test-runner sources/projects live only under
`build/DeviceDiagnostics/`; neither is a normal Obadh target.

The public extension-side geometry does not currently provide a verified way
to distinguish whether the host-owned band is present. Adding a compensating
18 points universally reproduces the taller bug demonstrated above. The
remaining OS margin discrepancy is therefore explicitly unresolved.

Raw local evidence: `build/key-color-investigation/` and
`/tmp/obadh-color-{baseline3,fixed,integration}.log`.
