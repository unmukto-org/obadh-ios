# Third-party notices

Obadh for iOS is licensed under the Mozilla Public License 2.0 (see `LICENSE`).
It builds on the following components, each under its own license.

## Linked into the app

| Component | Used for | License |
|---|---|---|
| [obadh_engine](https://crates.io/crates/obadh_engine) | Bangla transliteration, autocorrect, suggestions | MIT |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 1.13.8 | On-device speech recognition runtime (containing app only) | Apache-2.0 |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) (statically linked into sherpa-onnx) | Neural network inference | MIT |

## Downloaded on demand (not shipped in the app)

Voice typing downloads its models from the sources pinned in
`ObadhApp/Resources/VoiceModelCatalog.json`. They are not part of the app
binary and keep their own licenses:

| Model | Source | License |
|---|---|---|
| Bangla streaming Zipformer (vosk-model-small-streaming-bn 0.60) | Alpha Cephei | Apache-2.0 |
| IndicConformer bn (Conformer-CTC large), ONNX export | AI4Bharat; export by Parismita Global Solutions | MIT (model), Apache-2.0 (export) |
