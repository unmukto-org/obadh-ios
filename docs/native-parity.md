# Native parity: the measured model of iOS keyboard presentation

Obadh's goal is native geometry and appearance. This document records historical
measurements and the gates built around them; those are not OS guarantees or an
exhaustive verification of every current presentation path.

**2026-09-25 update:** [The presentation and font audit](keyboard-investigation.md)
reproduces a 17-point system-owned margin difference on iOS 26.5, fixes a transient
key-row jump, and measures previously ungated iPhone typography. Its current
findings qualify the older claims below. In particular, identical extension
geometry does not imply identical visible suggestion-zone height.

## What the gates cover, and what they do not

`scripts/parity/all.sh` runs every gate serially and reports one verdict.

| gate | devices | what it checks |
|---|---|---|
| `run.sh` | 6 iPhones x modern/legacy host x light/dark | zone height, q-row position, key fill, panel, glyph and strip **colour** |
| `iphone-landscape.py compare` | 6 iPhones | side inset, key height, pitch, key top/bottom |
| `ipad-geometry.py compare [--landscape]` | 5 iPads x 2 orientations | margin, gap, pitch, key top/bottom, per-row key widths |
| `ipad-type.py compare [--landscape]` | 5 iPads x 2 orientations | letter point size, flick-label size and opacity, command-glyph anchoring |

`ipad-type.py` exists because the geometry gate passed on a real iPad while the
keyboard still looked wrong. Key RECTANGLES matched native exactly; everything
inside them did not — letters 43% too large in landscape, flick labels 36% too
small and twice as bright, every command glyph centred where native anchors it.
A gate that measures only boxes will go green through all of that.

Honest gaps, so nobody reads a green run as more than it is:

* **Colour is gated on iPhone portrait only.** The iPad gates cover geometry and
  type. iPad dark mode has been measured by hand (the key fill and backdrop match
  native to the unit) but is not gated.
* **The command row is not measured by any pixel gate.** Its widths are covered by
  `KeyboardLayoutProviderTests` against the measured native table instead, which
  is why the regression in 7a7bc5f survived: those tests could not compile, and
  no pixel gate looks at the bottom row.
* **The emoji panel and emoji search are not gated at all.** Both are captured
  and inspected manually (`capture-emoji.sh`); the panel reports its own
  geometry through the debug channel's `dump`.
* **The flick animation is not gated.** Only its resting state is. XCTest can
  script gestures, but a measured flick-animation gate has not been added.
* Simulator only, except where this document says otherwise. The iPad type
  constants were confirmed against a physical iPad Pro 11-inch.

## How iOS presents a third-party keyboard

- The extension declares its height with a single Auto Layout constraint on
  its root view (`allowsSelfSizing` + one constraint, the documented
  mechanism). The system composites the view into a container it owns.
- **Metrics must derive from the intended height, never `view.bounds`.** The
  suggestion strip's required height feeds the view's fitting size, which is
  what the system sizes the container by. Deriving metrics from current
  bounds therefore creates a feedback loop that locks the container and, with
  self-sizing released, makes every height a fixed point (visible shaking).
- In the modern (Liquid Glass) presentation the system paints an unpaintable
  **band** above the extension inside its container — Apple's "new margin with
  edge and rounded corners above the top row" added in iOS 26. The visible
  suggestion zone is therefore `band + strip`. Measured: **16.0 pt on iOS 26.5**
  (invariant under a swept asked height 217→307 pt, repeated presentations, and
  host `inputAccessoryView`s of 0/44/88 pt) and **17.0–17.3 pt on iOS 27**.
- **On iOS 27 the band sometimes does not appear at all, and this is not
  detectable from inside the extension.** Cold-launched hosts have been measured
  with band 0 (zone = strip alone) while other presentations of the same build
  measure 17. Device-measured, fiducial-certified:

  | case | container top | our view top | q | band | strip | zone |
  |------|---------------|--------------|---|------|-------|------|
  | banded        | 609 | 626 | 662 | 17.0 | 36 | 53.0 |
  | band-less     | 626 | 626 | 662 | 0    | 36 | 36.0 |
  | band-less spec drawn under a band | 591 | 608 | 662 | 17.0 | 54 | 71.0 |

  **Do not add a detector for this.** One shipped briefly (`46268f2`) keyed on a
  sub-ask sizing intermediate, and correlated screenshots refuted it: presentations
  with byte-identical layout traces (`956*>|>255`) produced band 17.3 *and* band 0.
  The signature appeared in 7 of 56 logged presentations and did not predict the
  outcome. Also refuted as discriminants: presentation index (iOS builds a fresh
  view controller per presentation, so it is always 1), process age, and the
  view-controller-to-appear delay (one band-less case 1.86 s, another 0.27 s).

  There is no observable, by construction: the container is
  `band + ourView + systemBottomRow` with its bottom pinned to the screen, so our
  view sits at `screenBottom − bottomRow − ourHeight` with no band term. When the
  band vanishes the *container's* top edge moves and we do not — the q row stays
  at 662 either way. Confirmed by three further probes: the extension receives
  **zero** keyboard-frame notifications; `view.convert(bounds, to:
  screen.fixedCoordinateSpace)` returns origin (0,0); and no late layout pass ever
  fires (69 logged presentations, zero late heights).

  The strip is therefore a per-OS constant. `zone − band` is right whenever the
  band appears; when it doesn't, the zone is short by the band. That is preferred
  over the reverse error: drawing the full zone under a band that *does* arrive
  overshoots native by 17 pt, which is far more visible and was the regression
  the detector caused.
- **Legacy hosts** (apps predating the iOS 26 SDK, on iOS 26) get a different
  container: edge-to-edge, square, band-less, with its own geometry. There is
  no API for this either; the transient intermediates are class-quantized and
  disjoint (modern {294, 444, 452} vs legacy {260, 411, 419} across all width
  classes), so the keyboard detects legacy presentations from those measurements
  on iOS 26. Those anchors have not been validated on iOS 27, where the detector
  is disabled. Compatibility mode is **not universally removed on iOS 27**:
  [Apple clarified](https://developer.apple.com/forums/thread/838637) that apps
  built with Xcode 26 can retain it on iOS 27; the Xcode 27 SDK is what makes
  `UIDesignRequiresCompatibility` ineffective. A host's appearance must be
  measured rather than inferred from its name or the OS version alone.

## Geometry (all device-measured)

- **Key geometry is class-quantized, not proportional to width.** Native keys
  are 43 pt at widths below ~410 pt and 45 pt above, at 54/56 pt row pitch
  respectively, with an 11 pt row gap, near-constant across devices from the
  SE (375 pt) to the Pro Max (440 pt). A proportional `width/440` scale (our
  first model) sat key rows up to 18.5 pt below native's.
- **The suggestion zone is a design constant per OS**: ~51 pt on iOS 26,
  54 pt on iOS 27, uniform across hosts and widths. The strip we draw is
  `zone − band` in banded presentations and the full zone otherwise.
- Verified end state: our key rows land on native's exact pixels (q-row
  delta 0.0 pt at 402 and 440 pt), zones within 1 pt, on all 24 tested cells
  (6 devices × modern/legacy × light/dark).

## Color (sampled, then solved)

- The panel is `UIInputView(inputViewStyle: .keyboard)`, the system's own
  keyboard material, and it measures pixel-identical to native everywhere.
- Key fills are white-over-panel alphas solved from screenshot sampling:
  **0.16 dark / 0.87 light** (modern), **0.30 dark / opaque white light**
  (legacy). Native keys are flat: no shadow, no specular rim (a full-strength
  `UIGlassEffect` adds a rim native keys don't have; a flat translucent fill
  matches).
- Suggestion text centers ~26 pt above the strip's bottom edge regardless of
  strip height (native-measured rule), separators cap at ~27 pt.
- The key preview (press popover) is a plain rounded rectangle flush above the
  pressed key: native draws no stem/arrow and never overlaps the key face.

## The instruments

- **Probe overlay** (DEBUG): a live readout on the keyboard itself (bounds,
  window, asked height, rendered metrics, detected presentation) plus yellow
  fiducial hairlines at the view top and strip bottom, so any screenshot
  self-certifies our geometry with no detector heuristics.
- **Measurement backdrop**: the debug app's `--measure-bg` launch argument
  paints an appearance-independent mid-gray behind the keyboard so native's
  container edges measure cleanly in both light and dark.
- **`Debug-Legacy` build config**: the container app opts out of the modern
  design (`UIDesignRequiresCompatibility`), reproducing the legacy host
  presentation on demand.
- Measurement rules that survived contact with reality: read pixel *runs*
  (background → sustained material), never largest-brightness-step heuristics
  (they snap to accessory bars, labels, and our own fiducials, all observed);
  sample right of the probe label (it reaches ~0.88 × width on the narrowest
  device).

## Deliberately open

- Pressed-state key colors are relative values (scriptable now via the
  `preview:<key>` channel command; native's pressed state needs reference
  captures).
- Landscape and iPad zones are not yet measured.
- iOS 27 values should be re-verified at GA; the probe makes that a
  two-minute check.
