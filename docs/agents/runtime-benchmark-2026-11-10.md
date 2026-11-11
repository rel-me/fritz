# llama.cpp and mistral.rs performance on Fritz models

Measured on November 10, 2026, using an Apple M2 Pro with 32 GiB RAM and macOS 26.7.1.

llama.cpp completed generation on all 14 tested chat catalog entries. Fritz’s
pinned mistral.rs configuration completed 11. llama.cpp reached model-ready
sooner in every successful paired cohort. Generation throughput varied by model,
including near ties and cases favoring mistral.rs. Bosun selected the same
candidate on all 45 paired reference readouts.

The integrated backend migration and final installer sizes are documented in
[the application verification report](llama-runtime-migration-2026-11-10.md).

## Runtime and measurement setup

| Setting | Value |
| --- | --- |
| llama.cpp revision | `7c2653acc749258dc62067da62d07024d971ccd2` |
| mistral.rs revision used by Fritz | `4400935451da5e2dc7379a3f92fbbada66557f6c` |
| Build | Release, arm64, Metal enabled |
| Repetitions | Three sequential fresh processes per successful engine/model pair, alternating engine order |
| Chat workload | Identical 56-token ChatML prompt, greedy decoding, 8192-token context, one sequence |
| Requests per process | One-token request followed by a separate 128-token request with fresh sequence state |
| Input verification | Model sizes and SHA-256 verified against the catalog, prompt token IDs compared between engines |
| Cache conditions | Files read for checksums before inference, filesystem and Metal caches retained |

**Startup** is elapsed time inside the probe until the model and context are
ready. Rust timing begins after Tokio runtime initialization. A separate
one-token request preceded each 128-token request.

**Request throughput** is completion tokens divided by elapsed time for the
128-token request, including prompt prefill. Every successful paired chat cohort
used identical input token IDs and produced 128 output tokens. The C++ probe
collects token IDs, and the Rust completion API returns decoded text. These API
boundaries differ in host-side processing.

The table uses request wall-clock time. Supplemental engine decode timers used
different precision and host-side work, so their rates are omitted here.

## Chat results

Values are medians. Startup is in seconds and throughput is in output tokens per
second.

| Model, Q4_K_M catalog entry | llama.cpp startup | mistral.rs startup | llama.cpp request tokens/s | mistral.rs request tokens/s |
| --- | ---: | ---: | ---: | ---: |
| Qwen2.5 1.5B | 0.22 | Load failed | 107.20 | — |
| Qwen3 0.6B | 0.24 | 0.80 | 203.50 | 146.42 |
| Qwen3 1.7B | 0.26 | 0.90 | 105.56 | 85.75 |
| Qwen3 4B | 0.35 | 1.25 | 40.88 | 41.68 |
| Qwen3 8B † | 1.94 | 6.36 | 16.23 | 16.98 |
| Qwen3 14B † | 3.47 | 31.66 | 8.86 | 10.15 |
| Qwen3.5 0.8B | 0.26 | 1.28 | 143.25 | 81.59 |
| Qwen3.5 2B | 0.31 | 1.37 | 83.40 | 55.19 |
| Qwen3.5 4B | 0.39 | 1.70 | 33.87 | 28.39 |
| Qwen3.5 9B † | 4.37 | 9.86 | 18.35 | 17.67 |
| Qwen3.8 9B Distill † | 0.76 | 4.92 | 16.51 | 14.83 |
| Qwen3.8 27B UD | 2.03 | Load failed | 6.10 | — |
| Qwopus 27B Flash | 9.67 | 65.35 | 6.19 | 6.11 |
| Qwen3.6 27B | 3.38 | Load failed | 6.18 | — |

† The four 8B–14B rows are exploratory measurements on a working Mac with
uncontrolled background activity. A concurrent Fritz build was observed after
the early cohorts. The smaller models were repeated under the shared Fritz
build-cache lock, and those repeats supply their table values. All three 27B
cohorts also held that lock throughout inference. Timing runs were serialized
with model downloads and other inference probes.

### Load failures and coverage

- **Qwen2.5 1.5B** failed in the mistral.rs probe with an F32/BF16 addition
  mismatch. The staged Fritz CLI reproduced the same error using an isolated,
  keyless local-provider connection.
- **Qwen3.8 27B UD** contains an `IQ4_XS` tensor despite the Q4_K_M filename. The
  pinned mistral.rs direct GGUF binding rejected that dtype. llama.cpp completed
  all three generation runs.
- **Qwen3.6 27B** failed mistral.rs’s memory-admission check on this Mac. The error
  reported a 25,558 MB device budget and an estimated 1,451 MB excess. llama.cpp
  completed all three generation runs. This is an outcome of the tested
  configuration and hardware.
- **Apodex 1.1 Mini 35B** was excluded because its catalog guidance calls for
  48 GB RAM, exceeding the test Mac’s memory. It contributes no timing result.

Successful engines ran three times. An engine with a deterministic load failure
stopped after its first failed attempt in that cohort. Qwen2.5 CLI validation
first timed out at 10 seconds, then reproduced the dtype error on a second attempt.

### Qwopus artifact recovery

The catalog revision `9b90cd22b19276bc9e75c0e6d1665fa48619dd5b` returned HTTP 404.
The experiment retrieved the file from revision
`002f131b886df35843254e96425eb3a7e5a8cdd8` and verified its catalog-pinned size of
16,810,714,336 bytes and SHA-256
`1b76ad1596d6afc0b6e38a2b45b404462920739bd3087960b7a18a74ca938a74`.
The recovered bytes matched the original catalog pin.

## Bosun results

The Bosun cohort used the pinned `bosun-v3.1-0.6b-F16.gguf` and Fritz’s tokenizer
and serving contract. Both engines matched all 256 decision-token IDs and the
five frozen compiler-reference prompt token arrays. Each process evaluated
three rounds of those five prompts, giving 45 paired readouts across three
processes per engine.

mistral.rs used Fritz’s raw-logits request path with KV caching disabled.
llama.cpp read final-position logits and cleared context memory between rows.
Readout timing includes copying the eligible slot scores to host memory. Bosun
returned decision logits with zero generated output tokens.

| Metric | llama.cpp | mistral.rs |
| --- | ---: | ---: |
| Model-ready startup | 0.25 s | 1.66 s |
| First row readout | 55.42 ms | 100.10 ms |
| Warm row readout | 47.93 ms | 83.75 ms |
| First round of five readouts | 230.17 ms | 406.09 ms |

All 45 paired readouts selected the same top candidate. The maximum absolute
probability difference after softmax over eligible slots was 0.00098724,
approximately **0.10 percentage points**. The staged Fritz CLI also completed a
reference choice request through its normal decision harness.

These results establish agreement with the pinned mistral.rs baseline on the
five compiler fixtures. Official CPU parity, accuracy, calibration, and workflow
qualification require their own evaluation corpus.

## Related runtime size measurements

The preceding size experiment measured standalone inference payloads, including
their probe executable and required non-system libraries. Each payload was
stripped, ad-hoc signed, and compressed into an HFS+/UDZO image.

| Payload | Uncompressed | Compressed payload DMG |
| --- | ---: | ---: |
| llama.cpp | 10.22 MiB | 3.32 MiB |
| mistral.rs GGUF probe | 104.54 MiB | 39.36 MiB |

llama.cpp’s payload includes five dylibs and embedded Metal shader source. Its
first observed shader-compilation initialization in the size experiment took
8.663 seconds. That single observation and the later warm-cache measurements
have different cache conditions. The payload sizes exclude Fritz integration
code, Rust bindings, and any additional prompt or tool adapters.

## Interpretation and limits

The tested conditions favor llama.cpp for model-ready latency and Bosun readout
latency. Chat throughput has model-dependent trade-offs, especially among the
larger models. The three load failures also distinguish the tested runtime
configurations.

The experiment covers standalone completion and logit probes on one Mac using
one short chat prompt. Cold startup, long contexts, full application startup,
streaming behavior, cancellation, tool parsing, and model-answer quality remain
unmeasured. The exploratory rows and differing host-side API work limit close
throughput comparisons. A backend choice also needs the application behavior
and decision-model qualification described in the model evaluation procedure.

## Evidence retention

Bulk per-attempt JSON, token arrays, and embedded probe sources are kept outside
Git under `~/Builds/Machine/Fritz/benchmark-evidence/2026-11-10/`. This document
retains the results, pinned engine revisions, test conditions, and limitations.

- [Bosun compiler reference inputs](../../tests/fixtures/bosun-compiler-reference.json)
- [Model evaluation procedure](model-evaluation.md)
