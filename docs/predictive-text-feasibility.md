# Obadh predictive text feasibility study

**Research parked on 8 October 2026.** Model changes remain on
`feature/contextual-typing`; normal iOS development returns to
`feature/voice-typing`, and engine development returns to `main`. The current
correction reference is v5 mined step 6000. Later v9 filtering and v10 Gemma
reranking completed but failed nonregression admission. No neural model is
approved for production. See the engine research branch’s
[model handoff](https://github.com/nsssayom/obadh_engine/blob/feature/contextual-typing/tools/autosuggest/MODEL_HANDOFF.md)
for exact metrics, checkpoint hashes, known gaps and recovery.

All model-run data is being preserved in the
[private archive](https://github.com/nsssayom/obadh-model-runs). Its
`manifest.json` must report `status: complete` before local originals can be
removed. The owner requests local payload removal after remote verification
and an independent restore check. Clone with `GIT_LFS_SKIP_SMUDGE=1` and use
the archive’s `restore.py --fetch` to recover data with bounded staging space.
Earlier completion results below remain diagnostic; the latest correction
reference restores 704/985 synthetic examples and preserves 434/460 clean
inputs, with 87/171 contextual repairs and 166/171 clean-context preservation.
Those are reused development banks, not human-reviewed release accuracy.

Study date: 5 October 2026. Scope: Bangla typing, Roman-to-Bangla input, and mixed Bangla–English text inside the existing Obadh iOS keyboard and macOS input method.

**Recommendation: proceed with a compact, specialized language layer.** Substantially better completion and contextual spelling correction are feasible enough to justify a measured prototype. Local grammar suggestions are a plausible second stage. Broad Grammarly-level rewriting, with imperceptible latency across all supported iPhones, is not established by the available evidence.

The strongest route combines Obadh's deterministic engine and candidate retrieval with a small learned context model, conservative correction decisions, and training data that resembles actual typing. An off-the-shelf chat model is a useful experimental comparison, but a poor default dependency for every keystroke.

This study inspected the local repositories, reviewed primary platform/model/research sources, and ran small CLI probes against the iOS suggestion artifact. The initial audit did not train models. The implementation record below now includes verified corpus construction, A100 training, Core ML exports and Simulator measurements. A physical iPhone 11 benchmark and user acceptance measurements remain outstanding. Performance budgets, schedules, and proposed architectures below are hypotheses and planning targets, not achieved results.

**Latest measured outcome:** on a fresh, frozen set of 1,000 native Bangla
YouTube comments, the shipped n-gram model achieved 9.5% top-three exact next-word
accuracy; the selected word Transformer reached 12.3%, and the 17.3M-parameter
subword Transformer reached 14.0%. The latter is a 4.5 percentage-point / 47.4%
relative gain. This is evidence for continuing the neural approach, not a release
claim: the sample is topic-skewed, absolute accuracy remains low, autocorrection
is not evaluated by it, and no physical A13 measurement is available. Models
remain research artifacts; production predictions have not been replaced.

## What the current system actually does

The inspected snapshots were iOS `42701b7`, engine `96a3bcc`, and macOS `f09c84b`. The engine directory is `~/Dev/obadh_engine`. Both clients' Cargo lockfiles resolve engine **0.9.4**. The engine history includes the recent reph/ya and conjunct encoding fixes; installed binaries were not checked.

| Layer | Observed implementation | Consequence |
| --- | --- | --- |
| Transliteration | Synchronous deterministic Roman-to-Bangla preview | A useful fast foundation to preserve |
| Active-word correction | FST candidates ranked by frequency, channel priors, and edit/repair costs | No sentence context reaches the shipped correction API |
| Automatic insertion | Client thresholds: channel, costs, frequency floor 40, rare-word ratio 50, protected spellings | Conservative in some cases, frequency-driven in others; these signals are not calibrated probabilities |
| Active-word completion | Comes through correction candidate channels; iOS requests only visible slots plus one | Contextual completion needs both a wider internal pool and a new ranking path |
| Next-word prediction on iOS | Bundled c64 n-gram artifact plus personal overlay | Uses at most three recent known tokens for n-gram lookup |
| Neural next-word model | An 8.82M-parameter GRU package exists in the engine data repository | Not bundled or invoked by the inspected iOS client |
| macOS prediction | Its documentation explicitly says next-word autosuggest is not built | Desktop needs feature integration, not merely a model-file replacement |

Code evidence: [iOS query flow](../ObadhKeyboard/Sources/KeyboardViewController.swift), [composer](../Shared/Sources/Engine/KeyboardComposer.swift), [auto-insert gate](../Shared/Sources/Engine/AutoInsertGate.swift), [bridge](../Shared/Sources/Engine/ObadhBridgeClient.swift), [engine FST ranking](../../obadh_engine/src/autocorrect/fst_lexicon.rs), [engine context handling](../../obadh_engine/src/autosuggest/lm.rs), and [macOS terminology and feature coverage](../../obadh-macos/docs/vocabulary.md).

Several weaknesses precede model selection:

- **Context disappears after unknown words.** `AutosuggestContext.push_token_id` clears recent IDs for an unknown token. A name or Latin-script English word can therefore erase useful Bangla history. The existing neural collector also constructs contexts using this vocabulary contract.
- **Training domain differs from typing.** The corpus contains approximately 161.6M tokens: 105.6M news, 54.6M Wikipedia, and 1.47M books. Its 32,768-token vocabulary covers 91.94% of tokens in that corpus. Neither coverage nor quality on conversational typing has been established. English, names, abbreviations, and inflections need separate measurement.
- **Correction and prediction do not cooperate during composition.** The controller returns from the active-Roman-input branch before its next-word context lookup. A better n-gram artifact alone will not make active-word corrections context-aware.
- **Ordinary autocorrection can depend on result timing.** If a delimiter arrives before the async correction resolves, `commitActiveInput` resolves exact loanwords with ordinary auto-insert disabled. Measure behavior at realistic typing speeds, including this boundary race, before attributing every failure to model quality.
- **Session history is not always document truth.** iOS prioritizes personal session suggestions when it considers the cursor at the end. Context reconstruction after cursor moves, paste, deletion, and field changes needs its own evaluation. An unavailable right context must not be treated as proof of a known document end in a new editing contract.
- **Visible space is scarce.** An iPhone normally offers three text slots; literal preservation and emoji can reduce available alternatives. Optimize the actual displayed choices, not a top-5 research metric.

These observations identify mechanisms that can explain poor behavior. They do not establish each mechanism's share of the user's experienced failures.

## Reproduced suggestion behavior

The existing local engine CLI produced the following top three suggestions using the iOS-bundled artifact. These are diagnostic examples, not a representative benchmark or measurements of the complete keyboard UI/personal overlay.

| Context | Suggestions | Observation |
| --- | --- | --- |
| `আমি তোমাকে` | `ভালোবাসি`, `অনেক`, `নিয়ে` | Some familiar sequences work |
| `আমি আজ` | `এখানে`, `গতকাল`, `পর্যন্ত` | Sparse counts can produce awkward choices |
| `আমি কাল ঢাকা` | `বিশ্ববিদ্যালয়ের`, `মেডিকেল`, `মহানগর` | Lookup backed off to the frequent institutional uses of ঢাকা |
| `আজ meeting` | `ও`, `এবং`, `করে` | Zero matched context tokens; unigram fallback |
| `আজ মিটিং` | `করে`, `মিছিল`, `করতে` | Script choice materially changes the result |
| `আমরা আগামীকাল` | `আজ`, `সোমবার`, `শুক্রবার` | Count-based choices do not reliably capture the intended construction |

Reproduce from `obadh_engine`:

```sh
target/release/obadh-autosuggest suggest \
  --model ../obadh-ios/Resources/ObadhModels/autosuggest/autosuggest-ngram-c64.bin \
  --context 'আজ meeting' --top-k 3
```

The iOS artifact and engine c64 artifact had identical SHA-256 hashes:
`bbc221a46ac13433f2206b80772e08440e3b5165982a75430e6633710848a1f9`.

## What the existing neural model establishes

The [packaged GRU manifest](../../obadh_engine/data/autosuggest/models/neural/autosuggest-generator-gru256-topk128-c64-balanced.manifest.json) describes a 16-token context, a 32,768-word vocabulary, 128 generated proposals, and scores for 64 retrieved candidates. Its Core ML package is about 17.7 MB; the existing n-gram artifact is about 29.5 MB, using decimal MB. These are file sizes, not process memory.

The selected evaluation split reports:

| Metric | Static pool | Selected neural union |
| --- | ---: | ---: |
| Top-1 | 16.84% | 16.84% |
| Top-5 | 31.34% | 32.89% |
| Top-10 | 37.99% | 39.42% |

The top-5 gain is **1.56 percentage points**. The selected policy locks the first static candidate, so unchanged top-1 is a policy constraint, not proof that neural scoring can never improve it. The selected summary does not supply the neural top-3 result needed for the iPhone strip.

There are important limits to these numbers:

1. The split has 18,000 retained evaluation examples, balanced across EPUB/news/wiki. The training collector excludes unknown target words. Labels saying `all_targets` in a split report must not be interpreted as coverage of all words users type.
2. The n-gram manifest describes an all-corpus build. The available package does not establish a document-disjoint holdout for the entire retrieval-plus-neural pipeline. A neural holdout or policy-selection split alone cannot establish that. Rebuild vocabulary, retrieval counts, and training data under a common split before claiming generalization.
3. Reported local Core ML graph time around 459 microseconds is not keyboard latency on an iPhone. It excludes the evidence needed about extension memory, cold loading, scheduling, tokenization, and host-app interaction.
4. Export verification records changed top-k IDs after reduced precision. Validate final ranking and correction decisions after conversion, not just numerical tensor closeness.

Use this model as a low-cost baseline and integration experiment. Its present evidence does not justify calling it the desired deep upgrade. See also the [corpus documentation](../../obadh_engine/data/autosuggest/README.md), [vocabulary manifest](../../obadh_engine/data/autosuggest/models/ngram/vocab.manifest.json), and [example collection code](../../obadh_engine/tools/autosuggest/train_next_word_lm.py).

## Product scope and platform feasibility

| Capability | Feasibility assessment | Recommended behavior |
| --- | --- | --- |
| Contextual completion and next-word suggestions | High engineering feasibility; quality needs new evaluation/data | Update the existing ribbon asynchronously |
| Contextual typo correction | High engineering feasibility within a defined error distribution | Preserve the literal; silently replace only calibrated high-confidence typos |
| Local grammar errors such as agreement or suffix choice | Plausible, with substantial data/evaluation work | Offer a short editable span after a pause or word boundary |
| Long sentence restructuring and style | Higher uncertainty in an iOS extension | Defer or offer explicitly invoked proofreading on capable platforms |
| Full document review across arbitrary iOS apps | Constrained by host text access | Do not make this a baseline promise |

The feature can live inside Obadh's current keyboard. No separate writing app or replacement keyboard product is needed. This does not mean injecting a model into Apple's own keyboard: Obadh continues to be the selected input method.

Apple exposes surrounding text through `UITextDocumentProxy`, rather than direct access to the host text view. Design for missing or truncated context, and never assume a complete document. The keyboard also cannot place arbitrary grammar annotations inside another app's text view. The existing ribbon is the practical surface for a correction preview and acceptance. [Apple text interaction documentation](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards), [custom keyboard programming guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html).

Keyboard extensions have a separate memory limit, and Apple says limits vary by device. A universal “50 MB limit” is not a sound product specification. Obadh already has a [MemoryProbe](../ObadhKeyboard/Sources/MemoryProbe.swift); use it on supported devices during model loading and sustained typing. Shared files are storage, not a dependable always-running inference service in the containing app. Keep the baseline inference path inside the extension. [Apple keyboard memory guidance](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard), [extension architecture guidance](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html).

Bundle the baseline model so inference can work offline without network access. Test persistence and optional downloaded assets separately with Full Access both on and off; do not make local inference depend on an expanded sandbox. [Apple open-access documentation](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard).

macOS permits a more generous resource profile, but InputMethodKit clients still differ in their context and replacement behavior. Share models, normalization, ranking, and evaluation across platforms while keeping host editing adapters separate. The Mac repository also builds for Intel, so an Apple-Neural-Engine-only plan would not cover its current architecture targets.

## Model shortlist

Published language-understanding or general generation benchmarks do not establish Obadh correction quality. The roles below are recommendations for experiments.

| Candidate | Relevant evidence | Proposed role and limitation |
| --- | --- | --- |
| Existing Obadh GRU, 8.82M | Already exported to Core ML; matches existing vocabulary | First integration baseline; closed vocabulary, formal domains, modest recorded gain |
| BanglaBERT small, about 13M | Bengali ELECTRA encoder; small model is published | Strong candidate for a fine-tuned context ranker/error detector, subject to permission for intended use; it does not inherently generate corrections |
| sahajBERT, reported around 18M | Bengali ALBERT with Bengali tokenizer; model card lists Apache-2.0 | Useful permissively licensed encoder baseline; shared parameters reduce storage but do not eliminate repeated-layer compute |
| Custom 12–25M student | Proposed size, not a trained asset | Preferred longer-term candidate if it wins: short-context LM plus candidate features, trained for Obadh input and conversations |
| BanglaT5 small/base | Bengali sequence-to-sequence pretraining; base is 247M | Research comparator for grammar editing; autoregressive decoding and usage terms complicate keyboard deployment; inspect the actual small checkpoint rather than copying base-model metrics |
| SmolLM2 135M | Apache-2.0; primarily English | English-oriented control experiment, weak default Bangla foundation |
| Gemma 3 270M | Designed for specialization and fine-tuning; Gemma terms | Experimental decoder or desktop comparator; Bangla quality must be established for this exact size |
| Qwen3 0.6B | Multilingual causal model; Apache-2.0 | Desktop/offline comparator; too resource-heavy to choose as the universal extension baseline without exceptional device evidence |

Sources: [BanglaBERT small model card](https://huggingface.co/csebuetnlp/banglabert_small), [sahajBERT model card](https://huggingface.co/neuropark/sahajBERT), [BanglaBERT comparison including parameter counts](https://huggingface.co/csebuetnlp/banglabert), [BanglaT5 small](https://huggingface.co/csebuetnlp/banglat5_small), [BanglaT5 base](https://huggingface.co/csebuetnlp/banglat5), [SmolLM2 card](https://huggingface.co/HuggingFaceTB/SmolLM2-135M), [Google's Gemma 270M release](https://developers.googleblog.com/en/introducing-gemma-3-270m/), [Qwen3 model card](https://huggingface.co/Qwen/Qwen3-0.6B).

The official [BanglaBERT repository](https://github.com/csebuetnlp/banglabert#license) and [BanglaNLG repository](https://github.com/csebuetnlp/BanglaNLG#license) declare non-commercial research restrictions. Treat these checkpoints as permission-dependent for the intended distribution; open weights do not establish unrestricted product use. Distilling a restricted model is not an assumed way around its terms. Check checkpoint, tokenizer, training-data, and generated-data terms independently before choosing the production lineage.

Apple Foundation Models is worth a bounded compatibility probe, but should not be the foundation of Bangla support. Apple's current published Apple Intelligence language list does not include Bangla; the framework provides runtime language/availability checks. Eligible device coverage, exact on-device model selection, keyboard-extension operation, and latency would all need verification. Do not infer that the framework is categorically forbidden in extensions, or that every framework-backed model is local. [Apple language availability](https://support.apple.com/en-us/121115), [Foundation Models language checks](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models).

## Recommended architecture

Preserve deterministic preview on the immediate keypress path. Run the learned system asynchronously against an immutable snapshot containing preceding text, current Roman input, deterministic Bangla, available following text, cursor/field generation, and candidate provenance. A stale result may update neither the document nor the current correction decision.

**Completion and spelling:** retrieve approximately 32–64 candidates from the FST, Roman repairs, morphological alternatives, n-grams, and personal vocabulary. Keep the literal explicitly in the candidate set. Add a small context model to rank those candidates using language context together with Roman-input compatibility, edit costs, dictionary evidence, and acceptance/rejection history. A common word is not necessarily the intended word, and a language-model score is not a probability that replacement is safe.

First test a lightweight learned ranker using n-gram context priors and existing engine features. This provides a cheap baseline before neural inference. Then compare the packaged GRU, a compact encoder, and a custom causal model on identical candidates and splits. The engine already has Rust context-prior and neural handoff primitives, but the inspected C header exposes neither their full tensor handoff nor a context-bearing correction request. Integration requires versioned ABI additions, not only copying an `.mlpackage` into Resources.

**Next-word prediction:** keep retrieval as the immediate fallback and merge context-model proposals. For a new model, use a Bangla-aware subword vocabulary with Latin-script coverage and a character/byte fallback, so names do not erase history. Measure token fragmentation on mixed text. A next-subword prediction is not automatically a whole-word suggestion: either score retrieved complete words or use bounded decoding to a word boundary. Do not leave this search cost outside the latency measurement.

**Grammar:** evaluate a separate small edit tagger first. It predicts operations such as keep, delete, insert, or replace over a short span. GECToR demonstrates this approach for English; adapting its edit vocabulary and alignment to Bangla morphology is new work, not a solved transfer. Start with agreement, common suffix confusions, spacing, and punctuation. Use a bounded span decoder only if tagging cannot reach adequate recall. [GECToR paper](https://aclanthology.org/2020.bea-1.16/).

A practical first experiment uses a causal context model for completion/ranking and a separately evaluated encoder for grammar. Sharing weights is a later optimization if it preserves quality and simplifies memory use; loading both models at once must fit the extension budget.

Do not train everything as unrestricted “rewrite this sentence.” Train the model to preserve names, numbers, negation, tense, politeness, dialect, and already-correct text. Roman typos should be injected before transliteration as well as into Bangla output. A single QWERTY slip can expand into several Bangla code points, so raw Bangla edit distance is an incomplete error model.

Preserve the original document bytes and reversible span mappings separately from normalized model input. NFC, nukta variants, hasant, ZWJ/ZWNJ, and Bengali grapheme boundaries need explicit cross-platform tests. A model's preferred normalization must never become an uncontrolled rewrite of the user's entire buffer.

**Interaction policy:** high-confidence local typo correction may commit at a delimiter when enabled. Grammar and real-word ambiguity initially remain tap-to-accept. Display the affected span in the ribbon, revalidate its exact contents before replacing it, and retain a one-step undo record. Prefer the active word or recent suffix; reject an edit when the host cannot provide sufficient context to apply it safely. No late automatic rewrite after the user has moved on.

Keep personalization local through a small bounded word/phrase cache, explicit keep/reject signals, and reversible preferences. Avoid learning an automatically inserted mistake as positive evidence. Full on-device neural training or federated learning is unnecessary for the first product version.

Google's production research supports the broader approach: it uses small language models for core typing and larger models for proofreading, and reports benefits from adapting training text to mobile conversation. Its results motivate this design but do not predict a numerical gain for Bangla Obadh. [Google mobile language-model research](https://research.google/blog/synthetic-and-federated-privacy-preserving-domain-adaptation-with-llms-for-mobile-applications/).

## Memory and latency plan

Raw weight arithmetic explains why “small language model” is too broad a category:

| Parameter count | FP16 weights | INT8 weights | Ideal 4-bit weights |
| --- | ---: | ---: | ---: |
| 10M | 20 MB | 10 MB | 5 MB |
| 25M | 50 MB | 25 MB | 12.5 MB |
| 135M | 270 MB | 135 MB | 67.5 MB |
| 270M | 540 MB | 270 MB | 135 MB |
| 600M | 1,200 MB | 600 MB | 300 MB |

These are calculated decimal MB for weights only. Actual packages add scales and metadata; runtime adds activations, buffers, tokenizer, caches, compiled execution plans, UI, and existing engine state. Some weights may remain at higher precision. File mappings and accelerator allocations further complicate process accounting. Never use this table as a jetsam prediction.

Proposed prototype budgets, to revise after measurement on the oldest supported device:

| Operation | Initial target |
| --- | --- |
| Added synchronous keypress work | No neural inference; p95 under 2 ms of extra bookkeeping |
| Warm completion/correction update | End-to-end p95 under 30 ms; p99 under 60 ms |
| Grammar suggestion | Debounce around 250–400 ms, then p95 processing under 150 ms |
| Neural loading | Deferred; deterministic keyboard remains usable immediately |
| Additional neural peak footprint | Aim for 10–20 MiB first; actual limit comes from device profiling |
| Resource failure | Drop to existing deterministic/retrieval path without losing input |

The 10–20 MiB footprint goal may reject even a nominally small 25M model once execution buffers are included. If so, shrink the model, retrieve fewer candidates, reduce context, or run grammar less often; do not relax typing reliability to retain a model size.

Use Core ML as the first Apple deployment path. Compare CPU-only, CPU/Neural Engine, and other supported compute configurations on actual hardware. Start with fixed sequence lengths such as 32/64 tokens and batch size one, then benchmark candidate scoring as a batch where appropriate. Conversion success does not prove accelerator placement. Apple's transformer work demonstrates that tensor layout and buffer allocation can matter greatly, while Core ML's quantization guidance distinguishes weight compression from activation/compute savings. [Apple transformer deployment research](https://machinelearning.apple.com/research/neural-engine-transformers), [Core ML optimization guide](https://apple.github.io/coremltools/docs-guides/source/opt-overview.html).

Measure cold load, first inference, sustained typing, p95/p99 latency, peak footprint, memory-pressure recovery, thermal behavior, and energy against the same replay workload with ML disabled. Test at least the oldest supported iPhone, a midrange device, a recent device, iPad, Apple Silicon Mac, and Intel Mac if retained. Simulator and desktop graph timings are insufficient.

## Data and training feasibility

The existing corpus is enough to start experiments with a small model. It does not establish sufficient conversational coverage or permission for every source. Preserve source provenance and document IDs, audit the news/book inputs, and split by document before building vocabulary or n-gram counts. For synthetic data, keep all corruptions of one clean sentence in the same split. Group conversations and authors where feasible and check near-duplicates across splits.

| Data source | Useful role | Limitation |
| --- | --- | --- |
| Existing Obadh corpus | Initial language modeling and retrieval baseline | Predominantly news/Wikipedia; source rights need a manifest |
| Newly authored, consented Bangla conversations | Names, casual forms, everyday context, mixed English | Requires native-speaker collection and review |
| Real Obadh typing examples supplied voluntarily | Roman variants, repeated letters, key slips, user acceptance | Must be representative; do not collect private typing by default |
| Synthetic errors through Obadh's transliterator | Large targeted spelling/completion training set | A synthetic-only test overestimates real-world quality |
| BanglaGEC | Large grammar training candidate; card reports 7,074,425 pairs and CC-BY-4.0 | Audit clean references, source provenance, error realism, and split overlap |
| Vaiyakarana | Bangla error taxonomy and real/synthetic evaluation material | Pin the release; paper versions differ, and distribution terms need checking |
| BaTEClaCor | Additional error classification/correction research | Repository declares non-commercial licensing |

Sources: [BanglaGEC dataset card](https://huggingface.co/datasets/nahid-hub/BanglaGEC), [Vaiyakarana published paper](https://aclanthology.org/2025.findings-acl.431/), [Vaiyakarana repository](https://github.com/Bangla-iitk/Vaiyakarana), [BaTEClaCor repository](https://github.com/SyedT1/BaTEClaCor).

Recommended training order: establish a clean evaluation set; adapt a compact baseline to conversational Bangla; train correction ranking on Obadh candidate sets with a keep option; calibrate automatic insertion separately; then train grammar editing with substantial unchanged-text examples. Compare continued pretraining/fine-tuning with a custom student on the same data. Training a general foundation model from scratch is unnecessary; training a narrow 12–25M model from scratch is a reasonable experiment if it avoids an unsuitable tokenizer or restricted base.

Use stronger permitted models offline to propose synthetic conversations, edits, or ranking targets, with native-speaker review. Distillation cannot rescue poor teacher corrections or missing candidate coverage. Maintain a human-written holdout that no teacher generated or tuned against.

The first trials can target a single 24–48 GB GPU with short sequences and appropriately sized batches. This is a planning assumption, not a measured capacity requirement. Benchmark steps per second before reserving larger compute. As an initial spending control, cap the small-model exploration at 100 GPU-hours and review quality before extending it; teacher generation and annotation are separate budgets. No GPU jobs or paid resources were started for this study.

## Evaluation and release decisions

Build separate evaluations for completion while a prefix is present, next-word prediction after space, correction of the current word, and grammar edits. Mixing them hides failures. Include at least several thousand independently authored contexts, real Roman typing traces, and a large clean-text set; bootstrap intervals by document or conversation rather than treating adjacent tokens as independent users.

Required slices include formal Bangla, conversational Bangladeshi and West Bengal usage, dialectal forms, Banglish/Roman variants, mixed English, names, unfamiliar words, punctuation, emoji, digits, cursor edits, paste, and missing context. Native reviewers should allow multiple valid corrections and mark intentional register choices.

| Dimension | Measure | Proposed decision criterion |
| --- | --- | --- |
| Candidate generation | Intended correction recall@32/64 | Diagnose recall failures before ranking; target at least 95% on agreed in-scope typo classes |
| Visible suggestions | Top-1/top-3, actual visible-slot recall, acceptance, net keystrokes saved | Seek at least 20% relative top-3 improvement over the shipped baseline on the same held-out conversational set, with no material critical-slice regression |
| Automatic correction | Precision among replacements; harmful changes on clean input; recall and abstention | Target at least 99.5% replacement precision and at most one harmful change per 1,000 clean words; require useful correction recall so “never correct” cannot pass |
| Grammar suggestions | Edit precision/recall, F0.5, valid-text preservation, meaning preservation | Initially target at least 95% human-judged precision at a reported nontrivial recall; remain tap-to-accept |
| Runtime | Cold/warm p95/p99, memory, energy, reloads | Meet device budgets inside the real extension, with deterministic fallback |
| Interaction correctness | Stale-result application, undo, cursor/field changes, Unicode spans | Zero wrong-field or stale-span edits in the replay suite |

These are proposed gates, not industry guarantees. Report uncertainty and sample sizes, especially for rare harmful edits. Establish baseline correction recall during the spike and then choose an explicit minimum at the precision target. Sentence BLEU or perplexity alone cannot decide whether the keyboard is safe and useful. Also evaluate prediction under progressively mistyped context, rather than only perfectly clean preceding text.

Run ablations to attribute gains: fixed context handling; conversational data; context-aware non-neural ranking; existing GRU; compact pretrained encoder; custom student; personalization; quantization. Use exactly the same retrieval split and visible-slot policy. Teacher and full-precision quality are not substitutes for testing the shipped compressed artifact.

## Implementation sequence and effort

Planning estimate: one ML engineer, one engineer covering Rust/iOS/macOS integration, and part-time native Bangla reviewers. Licensing permission, dataset collection, or weak initial results can extend these ranges.

| Stage | Planning time | Concrete exit result |
| --- | --- | --- |
| Feasibility spike | 2 weeks | Reproducible held-out benchmark; current pipeline diagnosis; device memory/latency profiles; lightweight ranker and existing-GRU comparison; initial compact-encoder conversion probe |
| Contextual typing MVP | Additional 4–8 weeks | Context-aware completion and typo ranking in the existing keyboard; calibrated insertion and undo; local personalization; compressed-model device validation |
| Grammar pilot | Additional 6–12 weeks | Reviewed Bangla edit dataset; bounded grammar suggestions; host replacement tests and a user acceptance study |

Data work should start immediately and continue through all stages. A strong grammar product may require several further months; the estimate does not promise general writing-assistant parity.

Engine work includes candidate/feature export, versioned context and model contracts, Unicode/tokenizer alignment, evaluation tools, and a deterministic fallback. Swift work includes a Core ML runner, snapshot/generation tracking, cancellation, scheduling, memory handling, calibrated policy, and edit/undo behavior. macOS work includes next-word prediction integration and its own host-context adapter. Preserve the current separation where the engine exposes evidence and clients own insertion policy.

The first decision should be based on a two-week experiment: can contextual ranking plus better-domain data deliver a meaningful visible gain within the real extension budget? If the existing GRU provides little gain, that is a reason to compare better tokenization and data, not to immediately increase to a billion-parameter model. If the compact models cannot meet memory or quality targets, ship the measured retrieval/context improvements and keep grammar as a separate experimental tier.

## Decision

**Proceed with contextual completion and correction as the first product upgrade.** A small language model tailored to Obadh is a credible direction, and there are useful existing assets to start from. **Treat grammar as a separately gated capability** embedded in the same keyboard interface. The decisive work is a representative dataset, candidate coverage, safe editing, and physical-device measurements; model selection follows those results.

The feasibility study itself did not change application behavior or installed models.

## Implementation started

The iOS and engine repositories now have `feature/contextual-typing` branches; the
iOS branch starts from the completed voice-typing work. The first implementation
slice lives in the engine's `tools/corpus/`: reproducible document-level corpus
partitions, exact cross-split duplicate quarantine, and artifact/training lineage.
The engine's `tools/corpus/README.md` is the canonical workflow and source plan,
including eBanglaLibrary and candidate conversational/code-mixed Bangla datasets.
Platform runtime changes follow the shared benchmark and model evaluation gates.


The initial implementation now includes eight additional eBanglaLibrary books,
work-level held-out partitions, training/retrieval lineage checks, resumable GPU
checkpoints, and a separate frozen test evaluator. The engine's
`tools/autosuggest/TRAINING.md` records the GRU/transformer experiments and recovery
commands. The experiments compare 16-token word-level context models on the same
verified data; they do not yet establish conversational typing quality or grammar
correction. A native Core ML benchmark now measures latency percentiles and
process memory on macOS, with physical-device extension validation still required.


## iPhone 11 constraint and expanded model investigation

The product floor is the iPhone 11 family (A13), including newer iPhones. The
application currently targets iOS 18. This does not permit using newer Pro-only
features as the baseline. No physical iPhone 11 is connected in this session.
The dedicated iPhone 11 Simulator uses iOS 26.5 on an M3 Max; it validates the
extension integration, not A13 performance or device jetsam limits.

The completed experiment uses a compact causal subword transformer: byte-level BPE,
rotary positions, gated feed-forward blocks, tied embeddings, and causal scaled
dot-product attention. A training-only tokenizer has an 8,192-entry vocabulary.
The first tokenizer produced 125,529,312 subword tokens from 2,163,043
sentences. Its GPT-2-style pre-tokenization split Bangla combining marks away
from letters. A versioned Unicode-aware pre-tokenizer reduced the same text to
44,540,499 tokens; the phrase `আমি তোমাকে ভালোবাসি` takes four tokens instead of
sixteen. This retains unknown words as byte/subword sequences rather than
resetting context at a missing whole-word vocabulary entry. The current corpus
view is still Bangla-only; byte coverage does not establish code-mixed quality.

Large pretrained models were evaluated as offline teachers, independently
of what fits in the keyboard. Teacher candidate scores are bound to immutable
model file hashes, corpus partitions and candidate banks, and committed after
every context. Validation candidates never receive an injected correct answer;
OOV and retrieval misses remain in the denominator. Pretrained-model overlap
with public evaluation text cannot be ruled out by our own partition checks.
A strong teacher on generic benchmarks is insufficient: it must improve the
actual typing task before its outputs are used for distillation.

| Candidate | Investigation outcome or role |
| --- | --- |
| Qwen3 4B/14B Base | Offline whole-word likelihood teachers; compare complete-word boundary probability as well as raw token likelihood. Never deploy these weights in the extension. |
| Qwen3.5 0.8B Base | Newer hybrid model to investigate subsequently; its 873M parameters alone require about 437 MB at ideal 4-bit packing, before runtime costs. Not an iPhone keyboard baseline. |
| Gemma 3 270M | Potential teacher or aggressively reduced student; ideal 4-bit weights alone are about 134 MB. An ordinary app deployment is not evidence of extension feasibility. |
| mmBERT Small | Modern multilingual encoder, about 140M parameters including a large multilingual vocabulary. Vocabulary pruning and layer distillation are plausible; unmodified deployment is not yet budgeted. |
| BanglaBERT Small | 13M Bengali discriminator, relevant contextual pretraining; model metadata specifies CC-BY-NC-SA-4.0, so not selected as the default redistributable foundation. Its understanding benchmarks do not establish keyboard ranking quality. |
| sahajBERT | Apache-2.0 Bengali ALBERT; small unique parameter count hides 24 repeated 1024-wide layers. Must measure compute rather than judging by file size. |

Primary sources: [Qwen3 Base](https://huggingface.co/Qwen/Qwen3-4B-Base),
[Qwen3.5](https://huggingface.co/Qwen/Qwen3.5-0.8B),
[Gemma 270M](https://huggingface.co/google/gemma-3-270m),
[mmBERT](https://huggingface.co/jhu-clsp/mmBERT-small),
[BanglaBERT Small](https://huggingface.co/csebuetnlp/banglabert_small),
[sahajBERT](https://huggingface.co/neuropark/sahajBERT),
[public LLM distillation for compact on-device models](https://aclanthology.org/2024.findings-naacl.59/).

Compression is an independent accuracy experiment. Core ML supports
palettization and quantization, but actual decompression behavior depends on the
hardware and compute backend. A13 cannot inherit performance claims for the
A17 Pro/M4 integer activation path. Apple's published ANE transformer reference
specifically targets A14 and newer; its iPhone 13 speedups are not an iPhone 11
benchmark. [Core ML optimization guidance](https://apple.github.io/coremltools/docs-guides/source/opt-overview.html),
[ANE transformer reference](https://machinelearning.apple.com/research/neural-engine-transformers).

The 10M-parameter word transformer exported to a 20,053,058-byte FP16 package.
Linear 8-bit compression produced 10,202,229 bytes. On 900 known-vocabulary
validation fixture cases, pure candidate-ranking top-5 changed from 28.56% to
28.44%; this subset is not an all-target quality result. Naive 4-bit
palettization produced 5,109,350 bytes but retained the original top candidate
in only 76.1% of cases. It requires a proper quality evaluation and potentially
quantization-aware training; smaller files alone are not grounds to ship it.

The new DEBUG-only model probe executes these exported corpus fixtures in the
real keyboard process, away from the document input path. With the 8-bit word
transformer and the existing shipped retrieval artifact, CPU-only Simulator
inference left physical footprint at 38,602,984 bytes versus 37,849,320 before
loading; automatic compute selection left it at 77,941,016 bytes versus
37,898,472 before loading. Warm model-call p95 was 0.935 ms and 1.273 ms,
respectively. These are separate runs with runtime caches, not cold-device or
end-to-end typing measurements; they exclude replacing the shipped retrieval
artifact with the larger research artifact. The probe intentionally retains the
model and logs only exported corpus fixtures. Release compilation excludes the
probe and its command. The Simulator memory probe now reports unavailable
headroom instead of mislabeling zero as a real process limit.

Additional correction resources found: [BanglaGEC](https://huggingface.co/datasets/nahid-hub/BanglaGEC)
reports 7.1M synthetic correction pairs under CC-BY-4.0;
[DPCSpell](https://github.com/mehedihasanbijoy/DPCSpell) supplies a relevant
contextual spelling research baseline; [lekhya GEC](https://huggingface.co/datasets/lekhya-ai/gec)
explicitly warns against treating synthetic test scores as real-world quality.
These have not been admitted to training. Synthetic grammar labels need auditing
for meaning changes and legitimate variants, and all corruptions of the same
clean source must stay in one partition. Preserve clean/no-edit examples and
build an independently reviewed conversational benchmark before calibrating
automatic edits.

## Completed experiment and deployment decision

Both repositories are on `feature/contextual-typing`, branched from the inspected
voice-typing/iOS and engine heads. All training runs completed before the GPU
cutoff; neither allocation release nor Slurm cancellation was performed.

The corpus tooling now enforces train/validation/test provenance, document-group
partitioning, NFC exact-overlap quarantine, artifact checksums, atomic checkpoint
writes and resumable training. Eight additional books (81 chapters, 13,054
sentence chunks) were acquired with source receipts. Book partitions are by
work, not author. The combined verified corpus contains 145,494,563 training
word tokens; the bounded neural training view uses about 26.1M word tokens.
These are different quantities and should not be conflated with optimizer token
exposures. Near-duplicate and author-level leakage are not solved by exact
sentence checks.

A 5.5M and a 17.3M causal subword model each trained for 18,000 steps and
294,912,000 subword-token exposures. Both completed, saved and reloaded their
checkpoints. The larger model won both internal fixed-pool and open-vocabulary
validation comparisons. Its validation token loss was 3.6579 versus 3.9364 for
the smaller model. The selected whole-word Transformer has 10,005,504 parameters;
on the separate book/news/wiki test it achieved 21.81% top-three accuracy versus
18.94% for the training-only research n-gram baseline. That comparison is not
against the old shipped artifact and not against conversational text.

The fresh external benchmark uses [BanglaNostalgia's native YouTube comments](https://data.mendeley.com/datasets/ypwnbt5nfs/1),
CC-BY-4.0, downloaded from its [author-linked dataset](https://huggingface.co/datasets/ijahidul/BanglaNostalgia)
at revision `b3cb5a82316f098fc441764acead3f0bb050cb4b`. The receipt records the
attribution. One fixed contextual target is selected per comment; 54 exact
matches to our training sentences were excluded before sampling 1,000 comments.
Latin-script words and unknown context words remain in the subword input. None
of these comments was used for training or model selection in this experiment.
Selection and decoder settings were hashed and frozen before evaluation.

| Frozen external method | Top 1 | Top 3 | Top 5 |
| --- | ---: | ---: | ---: |
| Shipped n-gram artifact | 5.1% | 9.5% | 12.6% |
| Research n-gram artifact | 5.3% | 10.4% | 13.8% |
| Word Transformer, rerank 64 retrieved candidates | 6.4% | 11.4% | 15.2% |
| Subword Transformer, rerank the same candidates | 7.3% | 13.7% | 17.6% |
| Word Transformer, direct vocabulary generation | 6.7% | 12.3% | 16.1% |
| Subword Transformer, bounded open-vocabulary generation | 7.4% | 14.0% | 18.4% |

The paired-bootstrap 95% interval for the subword generator's top-three gain
against the shipped baseline is +2.5 to +6.3 percentage points; for the
preregistered word-generator comparator it is +1.2 to +4.5 points. These are
unadjusted exploratory comparison intervals, not a population-level guarantee.
12.7% of targets are outside the word model's vocabulary; the 64-candidate
research pool contains the exact target in only 34.2% of cases. The benchmark
has nostalgia/music topic bias, noisy spelling and dialectal references, and
no correction labels. A legitimate alternative next word can count as a miss.
After seeing these results, this set must not be reused for tuning and then
presented as a fresh release test.

The teacher comparison produced a useful negative result. On a fixed 1,500-row
internal validation bank, macro top-five accuracy was 23.47% for n-gram order,
19.0% for Qwen3-4B-Base complete-word likelihood, and 17.87% for
Qwen3-14B-Base. Larger pretrained teachers therefore were not blindly distilled
into this task. That does not rule out teacher-generated correction labels or
sequence-level distillation after a separate quality audit.

Deployment measurements separate model files, graph calls and keyboard-process
behavior:

| Artifact | Core ML 8-bit package bytes | Observed scope |
| --- | ---: | --- |
| Selected word Transformer scorer | 10,202,229 | Actual Simulator keyboard CPU p95 0.812 ms; current footprint 39.18 MB after inference, with caches and shipped retrieval already present |
| Small subword prefix graph | 5,659,439 | Mac Python/Core ML CPU p95 1.89 ms; not measured in a keyboard process |
| Large subword prefix graph | 17,554,513 | Actual Simulator keyboard CPU p95 25.27 ms, current footprint 40.13 MB; automatic compute p95 21.08 ms and 97.39 MB |

These are decimal MB, current physical footprints, and model-call timings—not
peak memory, A13 latency, cold-process budgets or complete decoding latency.
The measurements do not include loading the larger 45.3 MB research retrieval
artifact into the extension. The selected word scorer's 900 validation fixtures
were known-vocabulary cases; compression preserved its top candidate in 98.67%
of cases. The large subword FP16-to-8-bit comparison preserved next-token top-one
accuracy on 256 validation prefixes, but this is not quantized word-decoder
quality certification. Generic ONNX dynamic INT8 was unsuitable for the large
subword graph: only 57.8% top-candidate agreement, so it is not an admitted
portable deployment artifact.

Explicit KV-cache prefill and step graphs now export to ONNX and Core ML.
Tests establish equivalence to full-context PyTorch inference, mask future slots,
and check reset behavior. Across 32 validation prefixes followed by eight cached
steps each, ONNX preserved all top candidates (maximum logit error 2.86e-5);
Core ML with 8-bit weights and FP16 caches preserved 98.26%. Mac CPU p95 step
calls were 1.77 ms for ONNX FP32 and 3.82 ms for Core ML INT8. Each large-model
sequence uses 1,572,864 bytes of FP16 KV buffers: sixteen independent beams need
about 25.2 MB just for those buffers. Separate prefill and step packages may
also duplicate resident weights. Shared weights, cache ownership, bounded beam
search, cancellation and full-process measurements remain deployment work;
these graph exports alone are not a shipping decoder.

Verification includes 50 Python tests with optional training/export/parser
dependencies present, 147 existing Rust autosuggest tests, 67 iOS lifecycle tests,
keyboard enable/presentation and repeated-switching UI tests, and Debug/Release
Simulator builds. One earlier all-dependency Python run crashed at interpreter
shutdown after passing its assertions; the final full run exited cleanly, and
isolated ONNX export tests also exited cleanly. The diagnostic command and probe
remain DEBUG-only. None of these checks substitutes for a physical iPhone 11
thermal, latency, memory-pressure and long-session test.

**Decision:** continue with neural context, retain deterministic retrieval and
literal preservation, and keep the release gates. The fresh-data gain justifies
further work; it does not justify switching on automatic edits. Next production
work is a shared cancellable inference contract, efficient bounded generation,
conversational/mixed-script training data, and independently reviewed spelling
and grammar examples with clean/no-edit cases. Calibrate insertion separately
from suggestion ranking. Do not ship an experimental checkpoint by merely
copying it into the app bundle.

The durable artifact directory is
`/Users/nsssayom/Dev/obadh-model-runs/2026-10-05-contextual-v2`.
Its README records exact checkpoint locations, frozen source snapshots, metrics,
resume commands and the final file-hash inventory. The engine's
[`tools/autosuggest/TRAINING.md`](../../obadh_engine/tools/autosuggest/TRAINING.md)
describes the reusable tooling. macOS behavior and Unicode binaries were not
changed by this experiment.

## Quality-first follow-up: diagnosis and next experiments

The 14.0% external top-three result is not a production acceptance decision.
It measures an exact reference word without a typed prefix, and says nothing
about whether automatic corrections preserve the user's meaning. Keep this
metric, but add prefix completion, realistic typing-error recovery, reviewed
suggestion usefulness, and harmful edits per thousand clean words. Use separate
thresholds for displaying a suggestion and changing committed text.

A local coverage audit of the already-observed 1,000-comment bank found:

| Mechanism | Observation | Interpretation |
| --- | ---: | --- |
| Formal-domain training mix | 94.23% of used word tokens are news/Wikipedia | No conversational domain adaptation has been trained |
| Bounded training view | 26.12M of 145.49M available word tokens | The first runs did not use the full unique corpus |
| Subword exposures | 294.91M samples from 44.54M stream positions | Repeated exposure is not equivalent to more unique text |
| Context contains a word-vocabulary unknown | 54.9% of benchmark rows | The old word-model contract loses context frequently |
| Word-model context becomes completely empty | 14.5% of rows | Literal history is present but unavailable to that model |
| Exact target outside word vocabulary | 12.7% of rows | A fixed-word generator cannot produce those references |
| Exact target absent from 64 retrieved candidates | 65.8% of rows | A reranker alone cannot solve most target misses |

These context-reset figures apply to the word-based path; the new subword model
already retains unknown text. They do not explain away its remaining errors.
The audit is diagnostic on observed test data, not another unbiased evaluation.
Its hashes and counts are saved in
`/Users/nsssayom/Dev/obadh-model-runs/2026-10-05-improvement-audit/coverage.json`.

Prioritize the following controlled experiments before production integration:

1. **Data and context.** Expand unique pretraining coverage with deterministic
   document sampling, then adapt to native contemporary conversation and mixed
   Bangla/English. Preserve punctuation, numbers, names and turn boundaries;
   the current Bangla-only sentence view discards useful typing signals. Treat dialogue-rich modern fiction as a primary candidate source of natural
   conversational Bangla. Extract and preserve exchanges separately from
   narration, and measure the effect of that distinction rather than treating
   every book as formal prose. Split by work/thread/speaker where identifiers exist, and add
   near-duplicate checks. Do not use the observed comment test for adaptation.
2. **Matched-budget domain ablation.** Continue identical selected checkpoints
   for the same number of additional token exposures: expanded formal data in
   one arm, a preregistered conversation mixture in another. Compare on fresh
   grouped validation data and retain the old benchmark only as a regression
   diagnostic. This isolates domain adaptation from merely training longer.
3. **Keyboard objectives.** Train partial-word completion, phonetic/Roman input
   recovery and contextual spelling with realistic missing, repeated, adjacent,
   space-boundary and Bangla-character errors. Keep clean/no-edit examples.
   Compare a shared subword representation with separate lightweight prediction
   and edit heads against a compact dedicated correction model. Sentence
   likelihood alone is not a calibrated correction probability.
4. **Teacher adaptation and compression.** Evaluate an instruction-tuned Bengali
   or multilingual teacher on reviewed task examples; the previous base-model
   candidate-likelihood failure does not rule out synthetic dialogue generation
   or correction teaching. Filter and audit synthetic labels, including meaning
   preservation, then compare teacher-sequence/logit distillation to ordinary
   supervised training. Synthetic data remains augmentation, not the sole gold
   standard. Use quantization-aware training if post-training compression harms
   actual word/edit quality.
5. **Capacity within measured deployment budgets.** Compare the 8K tokenizer
   against a larger train-only vocabulary and compact model variants while
   reporting resident memory, cache cost and latency. Do not assume more
   parameters or a smaller file improves the keyboard. Keep the A13 target;
   large teachers remain offline.

This direction is supported by production mobile-language-model research.
Google reports benefits from conversational synthetic pretraining and subsequent
mobile-domain adaptation; those gains are evidence for testing the method, not
predictions of Obadh's gain. [Google Research, 2025](https://research.google/blog/synthetic-and-federated-privacy-preserving-domain-adaptation-with-llms-for-mobile-applications/).
Bangla-specific work also distinguishes real error distributions, synthetic
corruptions and actual correction ability; its human comparison does not justify
assuming grammar is solved. [Vaiyākaraṇa, ACL 2025](https://aclanthology.org/2025.findings-acl.431/).
Byte-level correction research supports testing synthetic pretraining followed
by curated real-error adaptation. [ACL 2023](https://aclanthology.org/2023.acl-long.402/).

Before the next training round, freeze a new multi-domain validation/test design
and a small reviewed typing suite. Track unconstrained next-word prediction,
completion by typed grapheme count, correction precision/recall, false edits on
clean text, and useful suggestions per typing session separately. No universal
exact-next-word percentage is asserted as shippable. Model candidates must pass
quality, latency, memory and no-edit requirements together.

No new training was launched in this follow-up: `chpc-gpu info` reported a missing
SSH master. Per the compute instructions, remote operations stopped. Restoring
that connection requires the user's password and Duo; allocation availability
must then be rechecked, without acquiring or releasing jobs automatically.


## Correction to the book-source assessment

The project owner's observation about modern Bangla fiction changes the data
priority: source medium is not linguistic register. Dialogue in novels can be
valuable conversational training material. The earlier statement that the model
had no conversational training data was too broad: existing book text can contain
dialogue, although no dedicated dialogue extraction or adaptation stage has been
trained. The 94.23% news/Wikipedia figure still describes the bounded corpus mix;
it does not establish that the remaining book text is non-conversational.

Inspection found a more actionable issue. The acquisition pipeline preserves
raw chapter text, but its derived training view tokenizes Bangla-only sentences,
removes punctuation and paragraph boundaries, and rejects spans with fewer than
two words. This can discard short replies and obscure question/answer structure.
The subword trainer consumes that derived view rather than the raw chapter text.
The retained raw chapters allow a new versioned, dialogue-preserving view without
rescraping. Dialogue need not be enclosed in quotation marks, so a quote-only
extractor is inadequate; uncertain turn or speaker boundaries must remain marked
as uncertain, not filled in with invented labels.

The eight-book acquisition plan includes Humayun Ahmed's *বোতল ভূত*, explicitly
assigned to **test**, and Zafar Iqbal's *টু-টু-টুনটুনি চু-চু-ছোটাচ্চু*, assigned to
**validation**. Neither newly acquired work contributed to that training run.
Those assignments remain fixed. This observation concerns the new eight-book
plan, not an assertion about every author in the pre-existing EPUB corpus.

The next data experiment should therefore include a curated literary-dialogue
arm as a first-class candidate:

- Select additional dialogue-rich works across authors, settings and registers;
  audit extraction quality and retain source/work/chapter provenance.
- Preserve short replies, punctuation, paragraph boundaries, adjacent turns and
  enough narrative context to interpret an exchange. Keep narration available
  as a separately sampled part of the corpus.
- Compare whole-book training, dialogue-enriched training, and a mixture with
  contemporary informal text using matched training budgets. Do not assume
  edited dialogue and mobile messages have identical distributions.
- Keep works and near-duplicate passages separated across splits, and reserve
  an unseen-author evaluation subset where metadata permits.

Books can supply clean, human-authored examples of conversational grammar and
interaction. Informal messages remain complementary for abbreviations, modern
mixed-script usage and actual typing errors. Their relative training weights
should be chosen by fresh validation rather than by a blanket preference for a
source medium. No new model was trained as part of this correction.
