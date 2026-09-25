# Draft: custom keyboard host retains preceding native keyplane padding

Status: prepared locally; not submitted. Height issue remains unresolved.

## Expected

A custom keyboard requesting the same content height should have the same outer
height when reached from English, Emoji, or app foregrounding. The text responder
and its 44-point accessory remain unchanged throughout.

## Reproduction

1. Present a normal `UITextView` with a 44-point `UIToolbar` as its accessory.
2. Select English (US), then a custom keyboard with a single 180-point input view.
3. Record `keyboardDidChangeFrameNotification` in the host.
4. Select Emoji, then the same custom keyboard; record again.
5. Press Home and foreground the host without changing the focused text field.

The minimal extension contains one button, with no suggestion engine or custom
touch handling. Generate the project's `inherited` probe variant to reproduce
using only public APIs. `host-trace` additionally enables simulator-only runtime
observation; it is not needed to reproduce and cannot build for physical devices.

## Measurements

iOS 26.5 (23F77), iPhone 17 Pro Max simulator, portrait:

| Custom keyboard entry path | Host keyboard frame height | Extension content height |
|---|---:|---:|
| English → custom | 316 | 180 |
| Emoji → custom | 299 | 180 |
| Foreground after the preceding state | 316 | 180 |

The button position and test text are unchanged. The additional area is outside
the extension's root view. Its bounds, window frame, safe areas, accessibility
screen conversion and keyboard layout guide do not expose the discrepancy.

On an iPhone 16 Pro Max with iOS 27.0 (24A435), the actual Obadh keyboard also
loses approximately 17 points above its root. A fully consumed 255 → 272 → 255
height pulse did not repair it. Physical implementation internals were not inspected.

## Narrowed mechanism on iOS 26.5

Runtime observation in our own test host shows retained native keyplane top
padding of 7 after English and 0 after Emoji. It stays at that value after
switching to the custom keyboard. The rounded-keyboard extra-padding calculation
produces 17 and 0 respectively. Foregrounding restores native keyplane top 7 and
extra padding 17. Accessory alignment uses this extra-padding calculation.

This is observed implementation behavior, not reliance on a private API in the
shipping extension. Please check invalidation of native keyplane layout state
when installing a third-party input view controller.

## Public approaches already checked

Explicit `.keyboard` and `.default` roots; system sizing; intrinsic and fitting
sizes; required content height; preferred content size; height pulses; replacement
input-view shell; primary-language updates; dictation-key refresh; and a
zero-distance cursor update did not stabilize the margin. The keyboard scene
rejects same-orientation geometry requests. The text proxy does not implement
the optional keyboard-type setter.

## Relevant existing report and evidence

[Developer report referencing FB21449121 and FB24460699](https://developer.apple.com/forums/thread/843093).
These are another developer's reports, not our own submissions or an Apple
confirmation.

Local captures and logs: `build/host-margin-investigation/host-trace-foreground/`
and `build/host-margin-investigation/logs/obadh-margin-host-trace-foreground-*`.
The UI test checks the host frame as well as the key frame, preserves the text,
and places its known-failure assertion last so the full sequence actually runs.
