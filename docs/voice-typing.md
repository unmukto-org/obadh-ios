# Voice typing (feature branch `feature/voice-typing`)

Offline Bangla dictation from the Obadh keyboard. Speech is recognized on the
phone in two passes: a small streaming model writes a draft while the user
speaks, and a Bangla Whisper fine-tune re-transcribes each phrase when the user
pauses and replaces the draft in place. Audio and text never leave the device;
the only network traffic in the whole feature is the one-time model download.

This document is the design of record for the branch. Status per part is at the
end.

## Platform facts that shape the design

These were verified before any code was written (September 2026, iOS 18 to 27).

1. **A keyboard extension cannot record audio.** It has no microphone access
   with or without Full Access, and it runs under a memory ceiling of roughly
   50 to 70 MB, which rules out any serious model anyway.
2. **The keyboard may open its own containing app, and only that app.** Apple
   DTS confirmed with App Review that guideline 4.4.1 ("must not launch other
   apps besides Settings") excludes the container app. The supported mechanism
   is walking the responder chain to `UIApplication` and calling
   `open(_:options:completionHandler:)`. Since iOS 16 this needs Full Access
   (without it the call fails with `-54`). Source:
   developer.apple.com/forums/thread/812091.
3. **Nothing returns the user to the host app automatically.** iOS shows the
   `◀ <Host>` breadcrumb at the top left; the user taps it (or swipes the home
   indicator). `_hostBundleID` is gone on iOS 18. Every shipping voice keyboard
   (Gboard, Wispr Flow, Dictus, WeChat and Doubao keyboards) lives with this.
4. **A backgrounded app cannot start the microphone.** It can keep a running
   recording alive with the `audio` background mode. So the first dictation of
   a session must bounce through the app, which starts the engine in the
   foreground; after that the engine keeps running in the background and later
   dictations start instantly from the keyboard. This is the "warm session"
   pattern every voice keyboard uses, and it is why the orange microphone
   indicator stays on while a session is warm.
5. **Live Activities can only be started from the foreground**, which is
   exactly when the bounce happens, and can be updated from the background
   while audio runs. The Dynamic Island is therefore the session's home.
6. **Apple has no Bangla speech model** (neither `SFSpeechRecognizer` nor the
   iOS 26 `SpeechAnalyzer`), so there is no system baseline to fall back to.

## Architecture

```
┌──────────── Host app (Messages, Notes…) ─────────────┐
│  ObadhKeyboard.appex  (no mic, ~60 MB cap)           │
│  • mic button leading the suggestion strip           │
│  • voice panel: listening visual, done / keyboard    │
│  • VoiceDraftReconciler writes draft → final text    │
└───────▲──────────────────────────────┬───────────────┘
        │ snapshot file + Darwin notify │ command file + Darwin notify
        │ level ring (mmap, 60 Hz)      │ open obadh://voice (cold only)
┌───────┴──────────────────────────────▼───────────────┐
│  Obadh.app  (foreground once, then background audio) │
│  AudioCapture → 16 kHz mono ─┬→ StreamingRecognizer  │
│                              │   (sherpa-onnx, CPU)  │
│                              └→ phrase buffer        │
│                                  → Refiner (sherpa-  │
│                                    onnx CTC, CPU)    │
│  VoiceSessionController · Live Activity · Models     │
└──────────────────────────────────────────────────────┘
```

### IPC (App Group `group.org.unmukto.obadh`, requires Full Access)

All files live under `<group>/Library/Application Support/Voice/`.

| Channel | Direction | Form | Why |
|---|---|---|---|
| `session.json` | app → keyboard | atomic JSON snapshot, monotonic `seq` | state, heartbeat, transcript segments |
| `org.unmukto.obadh.voice.snapshot` | app → keyboard | Darwin notification | "re-read the snapshot" |
| `command.json` | keyboard → app | atomic JSON, monotonic `seq` | start / stop / cancel with a dictation id |
| `org.unmukto.obadh.voice.command` | keyboard → app | Darwin notification | "read the command" |
| `levels.bin` | app → keyboard | 4 KB `mmap` shared page, seqlock | audio level + spectrum at display rate without notification spam |

Darwin notifications carry no payload, so each one only says "look again"; the
monotonic `seq` makes duplicate or coalesced notifications harmless. The level
page is written from the audio thread with a seqlock and read by the keyboard's
`CADisplayLink`, so the animation never waits on IPC.

A session is **warm** when `session.json` says `ready` or `listening` and its
heartbeat is under 2.5 s old. The app refreshes the heartbeat every second
while alive.

### Dictation flow

1. **Mic tap, session warm:** keyboard writes `start(id)`, flips to the voice
   panel immediately, and the app acknowledges within one audio buffer.
2. **Mic tap, session cold:** keyboard writes `start(id)` and opens
   `obadh://voice?d=<id>`. The app comes up on a dedicated listening screen,
   starts the engine at once (audio is buffered from the first buffer, so
   nothing said during model load is lost), starts the Live Activity, and
   points at the `◀` breadcrumb. Text dictated while on this screen is waiting
   in the snapshot when the keyboard reappears.
3. **Speaking:** streaming partials flow into the document as a draft that the
   keyboard rewrites in place (the same verified-suffix technique as
   `TextCompositionController`, so it can never delete text it does not own).
4. **Pause:** the streaming endpoint (trailing silence) closes the phrase. Its
   audio goes to the refiner; the refined text replaces that phrase's draft
   when it arrives. Refinement is serial, so settled phrases are always a
   prefix and the keyboard only ever tracks the unsettled tail.
5. **Done:** the app closes the open phrase, waits for the refiner (bounded),
   and marks everything settled. The keyboard returns to the keys.
6. **Idle:** the session stays warm for the user's chosen window (default
   5 minutes after the last dictation), then the app stops the engine, ends the
   Live Activity, and suspends. While idle the input tap discards every buffer:
   nothing is kept, processed, or written.

### Models

Both passes run on sherpa-onnx 1.13.8 (ONNX Runtime, CPU), one runtime for the
whole feature. A bundled catalog (`ObadhApp/Resources/VoiceModelCatalog.json`)
describes every model by role (`streaming` or `refiner`), runtime, files (path,
size, SHA-256), pinned source revision, device floor, and license. Models are
downloaded on demand into the app's Application Support (never the App Group:
the keyboard never loads them), excluded from backup, verified file by file,
and committed by a receipt written last. Several models per role can be
installed and one per role is active, so a better model is a catalog entry.

| Role | Model | Download | License |
|---|---|---|---|
| streaming | `alphacep/vosk-model-small-streaming-bn` 0.60 (Zipformer2 transducer) | 94 MB (27 MB once we host the int8 encoder) | Apache-2.0 |
| refiner | AI4Bharat IndicConformer bn large, CTC, int8 ONNX export | 198 MB | MIT (model), Apache-2.0 (export) |

A refined reading replaces the draft unless it is under 85 % of the draft's
length, which is treated as a CTC deletion (`VoicePhraseArbiter`).

#### How the models were chosen

Every candidate was scored with the same normalization on 150 utterances of
FLEURS bn (Indian Bangla, read speech) and 150 of SUBAK.KO test (Bangladeshi
Bangla, CC-BY-4.0). Harness: `scripts/voice-eval/`.

| Model | FLEURS WER / CER | SUBAK.KO WER / CER | Notes |
|---|---|---|---|
| Streaming Zipformer (int8) | 20.3 / 6.6 | 26.6 / 10.3 | only open streaming Bangla model |
| IndicConformer (int8) | 15.7 / 4.2 | 28.7 / 11.3 | best permissive offline model |
| streaming + IndicConformer, guarded (shipped) | 16.1 / 4.5 | 27.3 / 9.8 | |
| Hishab Conformer-large | 13.9 / 4.5 | 14.1 / 7.2 | CC-BY-NC-4.0, evaluation only |
| Mozilla Whisper large-v3-bn | 24.5 / 8.5 | | autoregressive, ~19 tokens per second of speech |
| Mozilla Whisper large-v3-turbo-bn | 27.8 / 10.1 | | |
| Gemma 4 E2B (speech-LLM) | 26.6 / 8.3 | 30.0 / 10.8 | 40-utterance sample; Latin digits, stray tokens |
| Meta Omnilingual CTC 300M | 36.5 / 9.4 | 53.6 / 21.9 | |

Whisper was the original plan and was dropped on these numbers: the Mozilla
fine-tunes report 9 to 11 % WER on Common Voice, the corpus they were trained
on, and are far weaker on unseen speech. Whisper's vocabulary also spends about
19 tokens per second of Bangla speech, decoded one at a time, so it was both the
slowest and the least accurate option. No phone-sized speech-LLM has usable
Bangla (Qwen3-ASR and Voxtral do not support it at all).

#### Bangladeshi accuracy: our own model

Permissive models are about twice as error-prone as Hishab's on Bangladeshi
speech. The plan is to train our own, openly licensed:

* **This Mac:** fine-tune IndicConformer (MIT) on permissive Bangladeshi data
  (SUBAK.KO train, Ben-10, Shrutilipi). Measured on the M3 Max: 120M-parameter
  Conformer training runs at about 120x real time, so ~450 h is ~4 h per epoch.
* **GH200 (when available):** a cache-aware streaming FastConformer (hybrid
  RNNT + CTC, NVIDIA base CC-BY-4.0) on ~3K permissive hours. One model that
  streams with near-offline accuracy would replace both passes. Estimated two to
  three GPU-days plus data preparation.
* Training data excludes non-commercial sets (Bengali.AI Kaggle, IndicTTS,
  BanSpeech is evaluation-only). OpenSLR 53 is CC-BY-SA and is opt-in.

### Keyboard UI

* **Mic button.** A fixed 44 pt slot at the leading edge of the suggestion
  strip; the candidates shift right to make room. SF Symbol `mic`, drawn in the
  strip's text colour at the strip's glyph size, with the strip's own pressed
  highlight, so it reads as part of the keyboard rather than a toolbar. A small
  teal dot appears on it while a session is warm. (The system dictation mic in
  the bottom band belongs to Apple dictation and cannot be intercepted.)
* **Voice panel.** Replaces the key area with a Metal-shaded, audio-reactive
  light ribbon in Obadh's teal-to-deep palette: layered glowing waves whose
  amplitude and brightness follow the level page, with an edge glow along the
  keyboard's top edge in the spirit of iOS Siri. Controls: a keyboard glyph
  (back to keys, stops dictation) and a Done button. Tapping the ribbon
  pauses. Reduce Motion swaps the waves for a gentle breathing glow.
* **Full Access off.** The mic stays visible and explains, inline, that voice
  typing needs Full Access (the keyboard cannot reach the app without it).

### App UI

* **Voice session screen** (`obadh://voice`): the same ribbon, full screen,
  live transcript, a large "Tap ◀ at the top left to go back" cue, and the
  session controls. Shown on every cold start from the keyboard.
* **Settings › Voice Typing:** enable, microphone permission, model manager
  (download, progress, optimize, delete, choose active per role), session
  length (1, 5, 15, 60 minutes), and a plain statement of what runs where.
* **Live Activity / Dynamic Island** (`ObadhVoiceActivity` extension): compact
  shows a waveform glyph (animated while listening) and the countdown until the
  microphone is released; expanded and Lock Screen show the state, a plain
  privacy line, and a Turn Off button. Turn Off is a `LiveActivityIntent` that
  writes an `endSession` command over the same App Group channel the keyboard
  uses. Live Activities are not a 60 Hz surface, so the Island shows state,
  not levels.

## Privacy

* No audio is written to disk. Utterance audio lives in memory until refined,
  then is dropped.
* Transcript text crosses to the keyboard through the App Group file and is
  removed when the dictation settles.
* No analytics, crash reporting, or remote configuration is added. The model
  download is the only network use and it carries no identifiers.
* `NSMicrophoneUsageDescription`, the privacy manifests, and the in-app
  Privacy screen are updated to say exactly this.

## Open risks (device gates before merge)

1. **Memory while backgrounded.** Both models on CPU are ~300 MB of weights
   (int8); the app must survive as a background audio app on a 4 GB phone.
   Measure with `idevicesyslog -m OBADH-VOICE` and jetsam reports.
2. **Refiner latency** on the device floor. Simulator on M3: 0.15 to 0.30 s per
   5 to 9 s phrase. Gate: p50 under 0.8 s on an A15.
3. **Phrase seams.** A mid-sentence breath can split a sentence; the refiner
   once invented a character at such a seam. Tune the trailing-silence rule on a
   whole-pipeline benchmark rather than single examples.
4. **App Review** for the background audio mode: justified by the recording
   itself; the idle discard and the session timeout are documented in review
   notes.
