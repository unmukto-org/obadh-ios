# Voice typing (feature branch `feature/voice-typing`)

Offline Bangla dictation from the Obadh keyboard. Speech is recognized on the
phone; audio and text never leave it. The only network use in the feature is
the one-time model download.

## The platform constraint, and the shape it forces

* A keyboard extension cannot use the microphone (unchanged through iOS 27).
* A backgrounded app cannot start recording, only keep one running.
* Nothing returns the user from the app to the host automatically. Apple DTS:
  no public API; `suspend()` goes to the Home Screen (developer forums thread
  826851). Keyboards that seem to do it rely on private API.

So there are two options: open the app to dictate, or keep the microphone
running (the orange indicator) between dictations. Obadh does the first, the
same shape as Gboard: the keyboard's mic opens Obadh's voice screen, the user
speaks there, and the final text is inserted when they go back. The microphone
runs only while that screen is in front. Rejected along the way: warm sessions
(persistent indicator), a Control Center / Action button control with a Live
Activity (not something everyday users set up), and private-API auto-return.

## Flow

1. **Mic tap (keyboard).** Commits the word being typed, records a pending
   dictation (persisted: iOS often kills the keyboard during the trip), and
   opens `obadh://voice?d=<id>` through the responder-chain `UIApplication`
   (App Review 4.4.1 allows a keyboard to open its own app; needs Full Access).
2. **Voice screen (app).** Already listening when it appears. Cancel and Done
   at the top, the words large in the middle (committed in the primary colour,
   the one still-settling word in secondary), the voice light below.
3. **Done, a long pause, or leaving the screen** finishes the dictation. The
   microphone is released and the model unloaded the moment the text is final.
4. **◀ Back.** The keyboard inserts the final text in one append and
   acknowledges; the app then forgets it.

Nothing is written into the host's field while the user speaks, so there is
nothing to rewrite there.

## Reliability and recovery

* Only the coordinator of the **appeared** keyboard may deliver. Disappearing
  removes its snapshot observer, and even queued notifications check ownership.
  A successor re-reads the persisted pending request rather than trusting a cached
  copy. The request is consumed before proxy callbacks can reenter delivery.
* Six seconds on return is a progress notice, not a deadline that deletes speech.
  If the user starts editing before a delayed result arrives, automatic insertion
  is cancelled; the unacknowledged result remains available in Obadh for Copy.
* Each recording owns a fresh pipeline and generation. Cancel, replacement,
  background departure during permission, and completion invalidate old callbacks.
  Duplicate URLs for the current trip do not restart it or erase its final text.
* Done allows at most 450 ms of post-roll capture. An interruption/departure clamps
  the endpoint to existing audio and stops capture immediately, including when
  already finishing. Finishing has a four-second deadline; model loading has a
  thirty-second deadline. The background-task expiration path also stops safely.
* A buffer overrun is an explicit failure, not a jump to newer audio. A long
  recording can run past the 60-second buffer capacity as long as recognition
  keeps up. Missing-audio/time-out results are **not** automatically inserted.
* Failures keep the latest recognized words, mark them incomplete, and offer Copy.
  A saved final/recovery result survives app restart until acknowledgement,
  explicit discard, or a new dictation. Foreground entry reads missed
  acknowledgements and exposes any remaining recovery text. Shared-file write
  failures are surfaced; if storage cannot be written, the in-memory text must
  be copied before leaving or process termination.
* Cancel publishes an empty idle tombstone for its exact trip, so a returning
  keyboard clears that request without inserting whitespace or waiting forever.
  Discarding nonempty text requires confirmation. Listening is a separate status
  capsule; finishing is explicit, and transcript text supports Dynamic Type.

The host's `insertText` API has no transactional receipt: a crash across the
pending-state/proxy-edit/acknowledgement boundary cannot be made exactly-once
across processes. We prevent duplicate attempts by live controllers, and keep the
app's recovery copy until acknowledgement; we do not promise that every host will
accept arbitrarily long text or that crash-time insertion can be verified.

Regression commands (no microphone or model download required):

```sh
swift test
xcodebuild test -scheme ObadhKeyboardLifecycleTests -destination 'platform=iOS Simulator,id=F6869131-DA8E-4E6D-B984-A7CCBB299818'
xcodebuild test -scheme ObadhVoiceTests -destination 'platform=iOS Simulator,id=F6869131-DA8E-4E6D-B984-A7CCBB299818'
```

Coverage includes startup/cancel/replacement races, stale recognizer callbacks,
post-roll interruption, finish deadlines, audio overflow, unavailable/write-failed
IPC, hidden/successor/reentrant delivery, slow final arrival, cancellation and
empty results, missed acknowledgements, 10,000-word serialization/insertion,
100 closed transcript segments, and 20 minutes of simulated ring consumption.
These deterministic tests complement, not replace, physical-microphone endurance,
Bluetooth/call interruption, and real-host acceptance tests.

## Recognition pipeline (app)

```
mic tap ─▶ VoiceAudioRing ─▶ worker (own cursor) ─▶ streaming recognizer
                                                    └▶ VoiceTranscriptBuilder
                                                         committed | tentative
```

* **Capture.** AVAudioEngine tap, converted to 16 kHz mono into a buffer
  allocated once; no per-buffer allocation. A route change rebuilds the tap and
  converter; a watchdog rebuilds a stalled engine once, then fails honestly.
* **Ring buffer.** Bounded single-producer / single-consumer ring (60 s) with
  monotonic 64-bit sample indices. A dictation is a span of positions taken at
  request time: 0.35 s of pre-roll before the tap, 0.45 s of post-roll after
  Done (none when the app is leaving). Audio that arrives while the model loads
  is read once it has. When not dictating only the last second is kept.
* **Worker.** Woken by a coalescing `DispatchSourceUserDataAdd`; reads in 100 ms
  steps. The recognizer runs continuously through a dictation: a pause commits
  words, it does not reset the stream. Four pause strategies measured on
  concatenated Bangladeshi speech were within about 1 WER point of each other;
  the continuous stream is deterministic and has no cold-start risk.
* **Commit policy.** The standard stable-prefix scheme: the last word is held
  back, a word commits once two consecutive hypotheses agree on it (local
  agreement, LA-2), and a pause or the end commits everything. Committed words
  are frozen.
* **Silence.** Energy voice-activity detection against an adaptive noise floor,
  with onset / offset hysteresis and a hangover. Eight seconds without voice
  ends the dictation.

## App ↔ keyboard (App Group `group.org.unmukto.obadh`)

| Channel | Direction | Carries |
|---|---|---|
| `session.json` + Darwin notification | app → keyboard | the dictation id, its final text once final, a failure |
| `command.json` + Darwin notification | keyboard → app | acknowledge (inserted), cancel |
| `levels.bin` (mmap) | app → app | audio level and spectrum for the light, written from the audio thread |

Snapshots are written only when the keyboard needs something (a dictation
started, its text became final), never per partial. Messages carry monotonic
sequence numbers, so duplicated or coalesced notifications are harmless.

Insertion uses `VoiceDraftReconciler` and `VoiceDraftWriter`: a separator
decided from the text before the cursor, scalar-exact anchors, and deletion only
while the document still ends with the exact text being replaced. For a final,
append-only delivery that reduces to one insert.

## Models

Downloaded on demand into the app's Application Support (never the App Group),
excluded from backup, verified file by file (SHA-256), committed by a receipt.
The catalog (`ObadhApp/Resources/VoiceModelCatalog.json`) supports several
models per role; one per role is active.

| Role | Model | Size | License |
|---|---|---|---|
| streaming | `alphacep/vosk-model-small-streaming-bn` 0.60 (Zipformer2 transducer), sherpa-onnx 1.13.8, CPU, greedy search | 94 MB (27 MB int8, not yet hosted) | Apache-2.0 |

### How it was chosen

Same normalization, 150 utterances each of FLEURS bn (Indian, read) and
SUBAK.KO test (Bangladeshi, read). Harness: `scripts/voice-eval/`.

| Model | FLEURS WER / CER | SUBAK.KO WER / CER | Notes |
|---|---|---|---|
| Streaming Zipformer (int8) | 20.3 / 6.6 | 26.6 / 10.3 | shipped; greedy is 0.5 WER worse than beam but never revises a shown word |
| IndicConformer bn (int8) | 15.7 / 4.2 | 28.7 / 11.3 | tried as a second pass; broke case endings on real clips (অফিসে became ওফিস এ) |
| Hishab Conformer-large | 13.9 / 4.5 | 14.1 / 7.2 | CC-BY-NC-4.0, evaluation only; collapsed on a 1 s real clip without silence around it |
| Mozilla Whisper large-v3-bn | 24.5 / 8.5 | | autoregressive, ~19 tokens per second of speech |
| Mozilla Whisper large-v3-turbo-bn | 27.8 / 10.1 | | |
| Gemma 4 E2B (speech-LLM) | 26.6 / 8.3 | 30.0 / 10.8 | 40 utterances; Latin digits, stray tokens |
| Meta Omnilingual CTC 300M | 36.5 / 9.4 | 53.6 / 21.9 | |

Read speech flatters every model. The owner's own recordings
(`~/Dev/obadh-voice-training/sayom-real-data`, `text/<n>.txt` + `voice/<n>.*`)
are the benchmark that decides; `scripts/voice-eval/` builds them into a set.
Better Bangladeshi accuracy (own fine-tune, or a streaming FastConformer on a
GH200) is parked for now.

## Keyboard UI

The mic leads the suggestion strip (a fixed 44 pt slot in the strip's text
colour and pressed highlight). The keyboard draws no dictation UI: the only
voice words it shows are problems the user must act on (Full Access, the
download, the microphone permission).

## Privacy

No audio is written to storage. The ring holds at most the dictation plus a
second, only while the voice screen is open. The text crosses to the keyboard
once, when final, and is deleted on acknowledgement. No analytics or remote
configuration. The model download carries no identifiers (no cookies, no cache,
fixed User-Agent) and goes only to the catalog's pinned URLs.

## Open items before merge

1. Device verification of the one-shot flow across hosts (Messages, WhatsApp,
   Notes, Messenger), including leaving mid-dictation.
2. Host the int8 streaming model (27 MB) on `huggingface.co/unmukto`
   (publishing is the owner's step).
3. Acknowledgements page (sherpa-onnx, ONNX Runtime, model authors).
4. The owner's real-recording benchmark grown to a few hundred clips.
