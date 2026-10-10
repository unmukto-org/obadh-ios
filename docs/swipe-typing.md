# Swipe typing: iOS feasibility and production gate

Status: research and shared decoder foundation on `feature/ios-swipe-typing` and
`obadh_engine`'s `feature/swipe-decoder`. **No swipe UI is enabled or shipped.**
The existing tap path and keyboard extension are unchanged.

## What can be reused

Obadh iOS already owns every key touch through `KeyboardTouchSurfaceView`, has
live key geometry for phone and pad layouts, and inserts words through one
composition/editor pipeline. Apple's custom-keyboard API permits touch views
and gesture recognizers within the extension. A swipe trace can therefore be
collected without overlaying a second keyboard or changing the system renderer.

Android's implementation has two separable pieces. HeliBoard tracks the trail,
suggestion strip, editor boundaries and languages. Its actual swipe decoder is
a separately downloaded Google binary, not a reusable iOS dependency. Android
also has an Obadh-derived, engine-verified Bangla phonetic vocabulary: 66,494
spellings and 60,000 Bengali words from the current `bn.fst`. The vocabulary is
portable data; the Android decoder and HeliBoard UI are not the iOS design.

The portable runtime boundary should be a shared engine component: input is
per-frame letter probabilities and limited preceding-word context; output is
ranked Bengali words, confidence and the matched Roman path. The iOS extension
owns the touch lifecycle, field policy, Core ML/ExecuTorch inference, candidate
presentation and editor transaction. Android can call the same decoder later.
No key touch, editor access, or UI implementation belongs in the engine.

## Accuracy evidence and model options

`Tools/Swipe/evaluate_shape_decoder.py` probes a geometry-only decoder against
the Android-generated, engine-verified TSV. With 60,000 most-frequent paths and
300 synthetic trails per condition (seed `20261010`), results were:

| Synthetic key noise / corner cut | Top-1 | Top-3 | Host p95 decode |
| --- | ---: | ---: | ---: |
| 0 / 0 | 89.7% | 98.0% | 2.25 ms |
| 0.15 / 0.10 key units | 87.0% | 97.0% | 2.27 ms |
| 0.30 / 0.20 key units | 71.7% | 88.0% | 2.25 ms |

These are **not human accuracy or iPhone latency figures**. They show that a
shape matcher alone is not an acceptable final decoder, even with Obadh's
vocabulary. The benchmark is standalone; it is not included in the app.

The strongest current candidate for the spatial stage is FUTO Swipe's
layout-agnostic 635K-parameter encoder (2.65 MB fp32). It emits 32 frames of
per-key probabilities from a 64-point trail and runtime key centers. The
released English/QWERTY decoder and context model do not solve Bangla; Obadh
would constrain the emissions to its verified Roman paths, map them to Bengali,
and use the existing Bengali context model for reranking. The released encoder
is under the **FUTO Model Weights License 1.0**, which requires an end-user
“powered by FUTO Swipe” notice if distributed. Its C++ inference library is
separately licensed; do not copy that implementation into Obadh. A second route
is to train an Obadh-owned encoder from the MIT-licensed swipe.futo.org human
trails and synthetic Bangla paths, using the published architecture. The choice
requires a real iOS runtime and accuracy comparison, not a paper assumption.

Sources: [Apple custom-keyboard guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html),
[FUTO Swipe paper](https://arxiv.org/abs/2606.25247),
[FUTO encoder card](https://huggingface.co/futo-org/futo-swipe),
[weights license](https://huggingface.co/futo-org/futo-swipe/blob/main/LICENSE.md),
[MIT swipe corpus](https://huggingface.co/datasets/futo-org/swipe.futo.org).

## Production contract

1. Trace capture must preserve today's tap, slide-to-correct, multi-thumb
   ordering, iPad flick, backspace hold and long-press behavior. Only letter
   keys in ordinary prose fields may start a gesture. Secure, URL, email,
   numeric, phone and editor-disabled fields remain literal.
2. Move handling stays on the UI thread and does no model work. A bounded,
   cancellable decoder query runs after a deliberate gesture, with a generation
   token so a field change, layout change, keyboard dismissal or next touch
   cannot insert stale output. The model loads lazily and is hash/version
   verified. No network or Full Access is needed.
3. Commit through `TextCompositionController`, preserving the existing
   autocorrect, suggestion, learning, spacing, punctuation and backspace-undo
   semantics. A candidate strip must expose alternatives before a user is
   trapped by a wrong choice. No silent insertion below a calibrated
   confidence threshold.
4. Evaluate held-out **human Bangla phonetic swipes** over multiple writers,
   devices, speeds, directions and backgrounds. Report top-1/top-3 accuracy,
   rare-word coverage, confidence calibration, false-gesture rate, and error
   rate by spelling length. Synthetic trails and Android's scripted paths are
   regression fixtures only. Compare against the Android gesture decoder on
   the same words where possible.
5. Profile extension resident memory, cold load, energy and p50/p95/p99
   gesture-to-candidate latency on the iPhone 11 family. Test real editors and
   iPhone 11 simulator layouts, accessibility, touch cancellation, rotation,
   rapid tap→swipe→tap and bilingual transitions before enabling a user-facing
   switch. The shipping gate requires better accuracy than the shape baseline
   and no measurable tap regression; exact thresholds are set from the human
   benchmark, not manufactured from synthetic data.

The current shared Rust foundation implements bounded TSV validation and
deterministic, trie-constrained CTC beam search with tests. It has not yet been
connected to an encoder or to iOS touch events. The next deliverable is a
reproducible human-trail evaluation and a small on-device inference spike,
followed by guarded keyboard integration only if both pass.

The real 66,494-row Android-generated artifact loads in 32 ms on this Mac in
an optimized Rust test. Ideal CTC emissions for `ami`, `tumi` and `bhalo`
decode to the intended Bengali words in 1.0–1.3 ms each. These figures exclude
touch collection and neural inference and do **not** predict iPhone 11 latency.

An isolated local probe then ran FUTO's published encoder through ExecuTorch
without adding its weights or runtime to the app. For idealized trails, the
encoder plus Obadh's own CTC search ranked `ami`, `tumi`, `bhalo`, `valo` and
`kemon` first; raw greedy decoding missed `bhalo` and `valo`. In a separate
human-trace probe, 1,000 test rows were read from the MIT-licensed FUTO swipe
corpus; 335 English target words also occurred as Roman paths in the Bangla
vocabulary. On **that filtered English subset**, Roman-path top-1 was 92.5%
and top-3 was 97.6%; optimized Mac decoder p95 was 3.48 ms. This is not a
Bangla human-gesture score, a representative English score, or end-to-end iOS
latency. It is evidence that a shared CTC decoder can turn a portable spatial
encoder's emissions into Obadh's verified Bengali candidates. The published
model was used only for a temporary local probe and is not in the repository
or app; the probe's downloaded weights and packages were removed afterward.

## Collecting human Bangla trails

The existing, separate `ObadhAccuracyLab` app now offers **Collect swipe
gestures** on its opening screen (or launch with `-swipe-study`). This study
uses `KeyboardLayoutProvider`, `KeyboardRowView` and the actual key metrics;
there is no approximation of the Obadh key positions. It prompts 11 verified
Roman/Bengali word pairs three times each, records timestamped normalized
touch points and all 26 actual letter centers, and saves a versioned JSON
session with source revision and FST provenance in its own protected Documents
directory. The file can be exported after the first completed gesture. It
contains no free text, editor content or network upload. Rotation/interruption
discards an unfinished stroke. The shipping Obadh app and extension are not
linked to this collector.

Build the study app with `scripts/build-accuracy-lab.sh`. It has its own bundle
ID (`org.unmukto.obadh.accuracylab`), so installing it does not replace the
keyboard. The simulator UI tests exercise both the older typing study and the
new swipe recording path; their prompted touch fixture is not a human accuracy
result.
