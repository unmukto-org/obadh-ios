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
│                              └→ utterance buffer     │
│                                  → Refiner (WhisperKit│
│                                    Core ML, ANE)     │
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

A bundled catalog (`VoiceModelCatalog.json`) describes every model by role
(`streaming` or `refiner`), runtime, files (path, size, SHA-256), pinned source
revision, device floor, and license. Models are downloaded on demand into the
app's Application Support (never the App Group: the keyboard never needs them),
excluded from backup, verified file by file, and installed atomically.
Several models per role can be installed; one per role is active. Adding a
model in a future release is a catalog entry.

| Role | Model | Runtime | Size | Notes |
|---|---|---|---|---|
| streaming | `alphacep/vosk-model-small-streaming-bn` 0.60, encoder/joiner re-quantized to int8 | sherpa-onnx 1.13.8, CPU, 2 threads | ~27 MB (fp32 is 94 MB) | Zipformer2 transducer, Apache-2.0. WER CV 17.9 %, FLEURS 20.6 %. int8 output identical to fp32 on the reference clip; RTF 0.03 on M3. |
| refiner (default) | `mozilla-ai/whisper-large-v3-turbo-bn` → WhisperKit Core ML | WhisperKit 1.1.0, ANE | TBD after compression | 0.8 B, 4 decoder layers. Normalized WER 11.05 %, CER 6.06 % (Common Voice 21 bn). Apache-2.0. |
| refiner (max accuracy) | `mozilla-ai/whisper-large-v3-bn` → WhisperKit Core ML | WhisperKit 1.1.0, ANE | TBD | 1.5 B, 32 decoder layers. WER 9.65 %, CER 4.88 %. Decoding is roughly 8× the turbo cost per token, so it is offered only on 8 GB devices and only if it meets the latency gate. |

Why turbo is the default refiner even though the brief named large-v3: the
refiner runs every time the user pauses, and its latency is the time the draft
stays on screen. Both models share the same encoder; the difference is the
autoregressive decoder, 4 layers against 32. Bangla is token-heavy in Whisper's
vocabulary, so decoder cost dominates. Turbo buys a ~1.4 point WER difference
back as a several-fold latency win. Large-v3 stays in the catalog so the user
can choose it, which is also the proof that model switching works.

**First load.** Core ML specializes a model for the Neural Engine on its first
load, which can take tens of seconds for a Whisper encoder. The app does this
straight after download ("Optimizing for this iPhone") so no dictation ever
pays for it. Later loads hit the system's cache.

**No network in the recognizers.** WhisperKit is given a local model folder
with `download: false`, and the app refuses to load a refiner whose folder
lacks `tokenizer.json` (otherwise WhisperKit would fetch one from the Hub).
The downloader sends no cookies and a fixed `User-Agent`, uses no cache, and
talks only to the pinned host in the catalog.

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
* **Live Activity / Dynamic Island:** compact shows the state glyph and a live
  level-free glyph (Live Activities are not a 60 Hz surface); expanded shows
  state, the session countdown, and an End button (a `LiveActivityIntent`
  that runs in the app).

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

1. **Neural Engine in the background.** GPU work is refused in the background;
   the ANE is believed to be allowed. The refiner is configured for
   `.cpuAndNeuralEngine` (never GPU) and this must be measured on device with
   the app backgrounded. Fallback: refine only while the app is foreground and
   keep streaming text otherwise.
2. **Memory while backgrounded.** Streaming (~60 MB) plus a compressed turbo
   refiner (target under 700 MB resident) must survive as a background audio
   app on a 6 GB phone. Measure with `idevicesyslog` and jetsam reports.
3. **Refiner latency** on the device floor (A15 / 6 GB). Gate: p50 under 1.2 s
   for a 5 s phrase.
4. **App Review** for the background audio mode: justified by the recording
   itself; the idle discard and the session timeout are documented in review
   notes.
