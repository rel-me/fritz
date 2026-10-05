# Local language and decision model comparison

The first frozen comparison favors Qwen3.5 4B Q4_K_M as a selection baseline.
Kev 4B matched its accuracy but was slower on this host. This is evidence for
selecting an experimental starting point, not a qualified browser agent or
a globally best model pair.

## Measured selection proxy

The Apple M2 Pro, `Mac14,9`, has 32 GiB unified memory. Each model received the
same twelve captured-state questions: six existing development cases and six
previously known holdout captures. Code constructed complete action candidates;
the language models returned opaque action IDs and Kev returned one typed Choice.
The supplied milestone bypassed planning. No browser action or native tool call
was executed, and these cases are not a new blind holdout.

| Model | Correct / 12 | Median child seconds | Largest child RSS, GiB |
| --- | ---: | ---: | ---: |
| Qwen3.5 4B Q4_K_M | 11 | 12.87 | 5.59 |
| Qwen3.5 9B Q4_K_M | 6 | 17.47 | 10.74 |
| Empero Qwen3.8 9B Distill Q4_K_M | 9 | 16.34 | 10.64 |
| Kev 4B, ONNX CPU | 11 | 28.36 | 8.42 |

All 48 planned attempts completed with known usage and successful process cleanup.
Incorrect and invalid responses remain failures. Every model failed the blocked
Reddit case's required handoff; Qwen3.5 9B returned an invalid element ref there
and on five other cases. An invalid label does not establish that its underlying
semantic choice was wrong. Kev corrected the distilled model's unresolved-source
choice under the frozen four-case selective gate, raising that projection from
9/12 to 10/12. It did not improve 4B. Each selective projection added 118.553
seconds of measured serial Kev cost.

Children loaded models afresh. Filesystem and Metal caches were uncontrolled.
The private chat configuration used 8,192 context tokens, at most 2,048 output
tokens and thinking off. RSS is a per-process measurement; neither separate
maxima nor model download sizes prove combined residency or 24 GB compatibility.
There is no 24 GB hardware result.

## Compact decision qualification

Bosun 3.1 0.6B F16 uses its learned final-prompt decision slots through the pinned
mistral.rs engine. Ordinary text generation would test a different contract.
Its compiler must match independent official prompt bytes, candidate permutation
and tokens. Five official CPU references must then agree with native F16
probabilities within 0.005 on every option and select the same candidate before
the separate twelve-case selection extension is admitted.

The first CPU reference returned exact prompt/tokens and probabilities but failed
owned-group cleanup admission; four cases were unattempted. That failed cohort
is retained. A separately frozen follow-up corrects the transport's grace timing
and reference-interpreter metadata without changing packages, weights, reference
inputs, grading or tolerance. Compiler checks alone do not establish model parity.
Bosun remains opt-in, and the existing Laya-first catalog order is preserved.

The corrected five-case CPU cohort completed with clean exits and exact compiler
tokens. Native F16 matched all five choices and token vectors, produced zero
answer tokens, and differed from the original CPU probabilities by at most
0.001288, below the frozen 0.005 limit. Rust's mirrored reference metadata differs
by at most one adjacent 64-bit float; the selection validator permits that bound
only for the mirror and grades native measurements against the original CPU
vectors. This is limited component parity, without workflow calibration.

The separate Bosun extension completed all twelve attempts: 6/12 correct,
with 3/6 development cases and 3/6 previously known holdout captures correct.
Every response was typed and valid, with clean process cleanup and no provider
failures or timeouts. Median child latency was 31.8576905 seconds, total child
latency was 400.664035 seconds, and the largest child RSS was 4,023,992,320 bytes
(3.747635 GiB). Reported usage was 7,962 input tokens and zero output tokens.

Bosun falsely selected completion for Hacker News pagination, GitHub label
filtering, eBay shipping, and the Hacker News and GitHub context holdouts. It
unnecessarily handed off the page-instructions holdout, but correctly handed
off the blocked Reddit case that all four original models missed. The smaller
RSS does not compensate for these selection errors or establish combined
residency.

Under the unchanged four-case selective gate, the derived host projections
fell from 11/12 to 8/12 for Qwen3.5 4B, 6/12 to 5/12 for Qwen3.5 9B, and 9/12
to 7/12 for the distilled Qwen3.8 9B. Each projection added 145.73262 seconds
of measured serial Bosun cost and 2,955 input tokens. These projections retain
the original host failures; they are not integrated browser-agent runs.

## Architecture and next qualification

Qwen3.5 4B with Kev is the next controlled pairing experiment: use the language
model for planning and synthesis and Kev for eligible typed decisions, with
Qwen3.5 4B alone as the comparison baseline. That host-only baseline remains
unbeaten here. Kev did not improve its selection accuracy, and Bosun degraded
the selective projection, so neither pairing is qualified for automatic use.
Combined memory and real 24 GB compatibility remain unverified.

The language model plans bounded milestones, reads evidence, supplies exact
authorized values and synthesizes answers. Application code owns evidence,
source relationships, complete legal candidates, freshness, permissions, native
execution and completion checks. A decision model selects one complete action
tuple when semantic judgment helps. Pass constructed decision state unchanged;
this does not add cleaning to the chat conversation. Confidence is neither
permission nor proof of completion.

Choose the selector before action selection. The measured selective projection
runs the host first and adds a decision checker; its costs do not estimate a
replacement policy. A frozen structural gate and independent calibration cohort
are needed before introducing probability thresholds.

Frequent local decisions need a persistent serial worker beside the current
one-shot interface. Bind it to explicit model-store and artifact identity, use
versioned private messages with request IDs, admit one request at a time, and
keep weights resident with independent state and no cross-request history or KV
reuse. Parent deadlines include loading; EOF, cancellation or deadline must
terminate and reap the owned process group. Expose loading, readiness, inference,
shutdown and idle unloading. This worker is proposed, not implemented here.

Worker reuse does not remove the current raw API's whole-vocabulary/all-position
CPU copy. A supported final-position/eligible-slot readout is another efficiency
target, requiring the same official probability checks and memory measurements.
The current adapter narrows after that copy and retains its explicit tensor cap.

Compare host-only, decision selection at each eligible step and structurally
gated selection on new independent tasks. Measure task completion, planning,
evidence coverage, native action success, fallback, cold/warm latency and actual
combined physical footprint with browser and operating-system headroom. Serialize
compute initially, then repeat on real 24 GB hardware. A model card or mock
provider check cannot substitute for these measurements.

## Reproducibility

`tests/local_browser_pairing.py` preserves the frozen 48-attempt protocol.
`tests/bosun_reference.py` independently extracts the official compiler.
The CPU, native-parity and separate selection scripts retain full probabilities,
usage, bounded raw outputs, artifact/source hashes and cleanup receipts. They
consume explicit installed models and do not read personal credentials or
download models during inference. Mock suites test admission and containment;
real model runs are opt-in.

Local evidence is retained under
`~/Builds/Fritz/worktrees/b6c23412fe218c99/local-browser-pairing/20261004T235700Z-248a65c5/`.
The retained evidence hashes are:

| Evidence | SHA-256 |
| --- | --- |
| Original 48-attempt report | `9980a1599b5d5ad6aaa5508376183e75c26aa9db0923d68216de3f3ad57bafaa` |
| Initial failed CPU reference receipt | `509a8875a0672a376d25168b85911933fdf316a7546361d1b8d8b95195a9497c` |
| Corrected five-case CPU reference receipt | `ee98e277a9b48e00758e57c21d0a4aa120fc4d0c35865830aaf0c1308c330c34` |
| Five-case native parity receipt | `121688136b051d80aa862bcf986bf42d3f0c91655e022e835befce84d4f7e4f7` |
| Twelve-case Bosun report | `a9260b487946bb8e8928e6183775a6fad92f8160e328fed6ed453976b59073ca` |
| Independent source/model/raw-output/cleanup closure | `f5a85cc1b88778c417d7786620ac0bd6f8ca175d7366a4e96136fbabf6b17ad4` |
| Terminal inference supervisor receipt | `b5e1640c732271818a27ea8c1f48e10a112b2e2aecf63d124a85e5922ff1b8f6` |

The corresponding application architecture, preregistrations and investigation
are published with [REL PR #632](https://github.com/rel-me/rel/pull/632).
