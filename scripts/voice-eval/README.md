# Voice model evaluation

The harness behind the model table in `docs/voice-typing.md`. Every model is
scored with the same normalization (`score.py`: NFC, zero-width joiners and
punctuation removed) on two fixed 150-utterance samples.

Run everything from one working directory (not the repo), laid out as:

    eval/                  test sets built by make_*.py, plus hypothesis JSON
    models/<name>/         downloaded model files
    venv/                  sherpa-onnx, onnxruntime, jiwer, soundfile, pandas
    nemovenv/              nemo_toolkit[asr] (Hishab / IndicConformer .nemo)
    wkvenv/, gemmavenv/    transformers for the Whisper and Gemma baselines

Test sets (no account needed):

* FLEURS bn test (CC-BY-4.0, Indian Bangla): `make_fleurs.py` from
  `huggingface.co/api/datasets/google/fleurs/parquet/bn_in/test/0.parquet`
* SUBAK.KO test (CC-BY-4.0, Bangladeshi Bangla): `make_subak.py` from
  `SUST-CSE-Speech/SUBAK.KO` `data/test-00000-of-00005.parquet`

Runners write `{wav: hypothesis}` JSON; score with
`python score.py eval/<set>/manifest.json <hyp.json>`.

| Runner | Models |
|---|---|
| `run_sherpa_stream.py` | streaming transducers (the shipped first pass) |
| `run_sherpa_offline.py` | sherpa-onnx NeMo CTC and Omnilingual CTC exports |
| `run_nemo.py` | any `.nemo` checkpoint |
| `run_hf_whisper.py` | Hugging Face Whisper fine-tunes |
| `run_gemma.py` | Gemma audio models |

`train_probe.py` times real Conformer training steps on the local GPU (MPS),
which is how the on-Mac fine-tuning estimate was made.
