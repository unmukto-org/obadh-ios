# Native-parity suite

Measures Obadh against the native keyboard (geometry and color) across device
width classes, host presentations, and appearances, on the iOS Simulator.
Measurements come from screenshots. Inspect captures as well: a detector can
misidentify a host accessory bar or an unintended input mode.

```
scripts/parity/all.sh                    # every gate below, serially, one verdict
scripts/parity/run.sh                    # iPhone portrait matrix, PASS/FAIL
scripts/parity/run.sh "iPhone 17 Pro"    # one device
SKIP_BUILD=1 scripts/parity/run.sh       # reuse existing sim builds
```

Four gates, because one shape of measurement is not enough:

| tool | covers |
|---|---|
| `run.sh` | iPhone portrait: geometry AND colour, 6 devices x host x appearance |
| `iphone-landscape.py` | iPhone landscape geometry, 6 devices |
| `ipad-geometry.py` | iPad key rectangles, 5 devices x 2 orientations |
| `ipad-type.py` | iPad key CONTENTS, 5 devices x 2 orientations |

`ipad-type.py` was added after a build passed every geometry gate and still looked
wrong on a real iPad: the key rectangles matched native exactly and everything
drawn inside them did not. If a gate only measures boxes, it will go green through
letters that are 43% too large.

Serial by construction. Parallel capture is slower on this hardware and produces
flaky shots (a device mid-boot screenshots the Apple logo), and the iPad landscape
gate needs exclusive control of Simulator's orientation menu.

Exit 0 means every cell is within tolerance. Artifacts (screenshots, probe logs,
`report.json`) land in `build/parity/<timestamp>/`.

## What it checks

Per device × {modern, legacy host} × {light, dark}, native vs Obadh:

| check   | what                                            | tolerance |
|---------|--------------------------------------------------|-----------|
| zone    | container edge → q-row distance                  | 3 pt      |
| q       | absolute q-row position on screen                | 2 pt      |
| keyfill | key fill color (median, away from the glyph)     | 4 / channel |
| panel   | material between key rows                        | 3         |
| glyph   | key text color                                   | 6         |
| strip   | suggestion-strip interior                        | 3         |

The device set covers both measured geometry classes (key 43 / pitch 54 below
~410 pt; key 45 / pitch 56 above) and the legacy-presentation detector
(`UIDesignRequiresCompatibility` host = the Debug-Legacy build of our own app).

## How it measures

- **Obadh is self-certifying**: with the probe overlay on, the keyboard draws
  yellow fiducial hairlines at its view top and strip bottom (= q row), and logs
  an `OBADH-PROBE` line with the screen size and rendered metrics. The suite
  reads the fiducials at x 0.90..0.985 W; the probe label must never grow past
  ~0.88 W (keep new probe fields on its shortest line). The label is also **taller
  than the modern strip** and overhangs ~10 pt into the first key row, so colour
  samples come from the **last key** in the row (x ≈ 0.943 W), clear of it. Sampling
  any key further left measures the label's black backing rather than the key —
  it read 58 vs native 78 in dark and 179 vs 246 in light, a false FAIL that only
  hit modern cells (legacy's 53 pt strip hides the label).
- **Native** has no fiducials: q comes from key-brightness bands (glyph-structure
  fallback), container edges from panel-color runs walking up from the q row.
  The debug harness's `--measure-bg` launch argument paints an
  appearance-independent mid-gray behind the keyboard so those runs have
  contrast in both light and dark. Never measure edges with a
  largest-brightness-step heuristic: it snaps to accessory bars, labels, and
  fiducials (all observed).
- Captures use XCTest Settings activation, `simctl`, and the DEBUG control
  channel (`scripts/sim-kbd.py`) without moving the Mac mouse. Fresh dedicated
  simulators are created on demand. Writing `AppleKeyboards` alone did not
  register Obadh on fresh iOS 26.5 simulators; the sweep now enables it through
  the real Settings UI and aborts if presentation is not confirmed.
- Native capture explicitly requests `en-US`; advancing once is not proof that
  the next keyboard is native English.

## Honest limits

- Runs against the **iOS 26.5 simulator runtime**, the only one installed with
  Xcode 26.6. iOS 27 truth comes from device screenshots (the fiducials make
  those self-measuring too; see the probe overlay switch in the debug app).
- Pressed-state colors are not covered (static captures).
- Colour is gated on **iPhone portrait only**. iPad colour has been measured by
  hand and matches native to the unit, but is not gated.
- The **command row** is covered by unit tests rather than any pixel gate, which
  is how the 7a7bc5f regression survived: the tests could not compile, and no
  capture looks at the bottom row.
- The **emoji panel, emoji search and the flick animation** are not gated. The
  first two are inspected via `capture-emoji.sh`. XCTest can script gestures,
  but a measured flick-animation gate has not been added.
- This orchestrator is an on-demand shell harness that manages simulators.
  It invokes the `ObadhKeyboardUITests` activation test. That separate XCTest
  suite also covers switching and foregrounding; it records the known 17-point
  system-margin defect as an expected failure.

## Additional investigation tools

`phone-type.py` compares unscaled home-row glyphs and optional UIKit font atlases.
`transition-lines.py` tracks probe markers through simulator recordings.
`generate-margin-probe.py` creates an isolated project with a minimal 180-point
keyboard for the system-margin reproduction. These are diagnostic tools, not
additional gates in `all.sh`. See [the investigation report](../../KNOWN-ISSUES.md#ki-001)
for commands, measurements, and limits.
