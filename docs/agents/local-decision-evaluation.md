# Initial Ollaya / Laya evaluation

Laya English is available as an **experimental, explicitly invoked** local
backend. It has not qualified for automatic reminder routing. No decision model
is paired with chat automatically, and this integration does not create reminders
or perform actions from a model judgment.

## Revisions and method

- Ollaya Rust crates and artifact recipe: `152ad20c88f8ea9b6d1acf3ed0e06b002d38b2b4`.
- Author's Laya weights: `convaiinnovations/laya` at
  `aa8c91ca088ec597df95a0d1c76b3063cb2ae5e8`.
- CPU fp32 graph, pinned tokenizer and temperature calibration, four inference
  threads, one question row at a time. Each harness verifies files and loads the
  model afresh. The graph allows 512 tokens shared between question and state.
- Measured September 26, 2026, on a 32 GB Apple-silicon Mac (`Mac14,9`).
  Timings include verification, loading, three questions, and
  process exit. Other build/test activity was present; these are not isolated
  performance benchmarks.

`tests/local_decision_inference.py` contains two fixed synthetic English sets,
each with six requests to create a reminder and six other statements/requests.
Each case asks a choice question, a noul question, and a score question. The
score checks typed output and structured legends, not subjective urgency quality.
The provisional reminder-quality gate is choice accuracy >= 80% and noul Brier
score <= 0.20 (lower is better).

The first set was evaluated with “What is the user's current request?” as the
choice instruction. After inspecting its failures, the choice instruction was
made explicit about creating a new reminder and excluding quoted/completed
requests and explanations. A separate held-out set was written before evaluating
that revised instruction. The criteria and model weights were unchanged.

| Set / choice instruction | Choice accuracy | Noul Brier score | Cold request time |
| --- | --- | --- | --- |
| Development / broad | 8/12 (66.7%) | 0.0494 | 4.18–15.06 seconds |
| Holdout / explicit | 7/12 (58.3%) | 0.1952 | 4.42–11.59 seconds |
| Holdout / explicit, staged release | 7/12 (58.3%) | 0.1952 | 4.46–11.31 seconds |

**Both choice runs failed the provisional quality gate.** False positives included
completed reminders, cancellations, definitions, and quoted requests. The noul
results were better on the development set but worsened on the held-out set;
there is no evidence here for transferring Jev thresholds or using a 0.5 cutoff
for automatic actions. Twelve cases per set cannot establish general accuracy or
probability calibration. A real workflow needs a larger representative dataset,
negative cases, an abstention policy, and independent validation.

## Runtime verification

The real model returned valid choice/noul/score answers and preserved structured
JSON score legends. Oversized state produced an explicit context error. The
cancellation check waits until native model memory exceeds 1 GB, then closes stdin
or sends SIGTERM. The initial implementation intermittently segfaulted after
emitting cancellation (3 of 6 reproductions); exiting without native global
teardown fixed all six repeated checks. This process performs no model-cache writes.

The deterministic `make test` suite covers provider boundaries, missing models,
credentials/endpoints, chat/default exclusion, download integrity/cancellation,
and the Jev-shaped transport. It does not download model weights. `make check`
checks formatting and Clippy. The opt-in evaluation deliberately fails its quality
gate when the model does not qualify; runtime success is reported separately.

The signed staged release app was exercised with an isolated `FRITZ_DATA_DIR`
and a keyless local mock chat provider. In dark appearance, the Providers UI
showed verification/loading, installed and missing-model states, explicit download
size/license, download progress and cancellation, and a saved Ollaya connection.
Ollaya was absent from the chat model picker. A saved connection returned a real
typed judgment through the bundled `fritz decide` command. The staged decision
harness also passed structured-output, context-limit, and all six native
cancellation checks; its separate quality gate failed as shown above.

After incorporating the shared management UI and grouped downloads from upstream,
the staged app was checked in light and dark appearances. Shared provider-table
multi-selection, double-click/context-menu editing, Save and Escape, the Advanced
section, provider errors, and installed/missing Laya states worked. The general
download browser switched between LLM and Decision catalogs, recovered from an
empty filter, and started/cancelled a Laya download through the decision installer.
Provider-specific sheets stayed category-scoped. The rebuilt CLI returned a real
local judgment. A live download network-error screen was not manually exercised.

## Reproduce

Use an isolated data directory inside the checkout. Installation is explicit;
the evaluation script itself never downloads or calls a remote provider.

```sh
export FRITZ_DATA_DIR="$PWD/dist/local-decision-evaluation"
target/debug/fritz decision-models install laya-en
python3 tests/local_decision_inference.py --data-dir "$FRITZ_DATA_DIR" \
  --suite development --question-style broad
python3 tests/local_decision_inference.py --data-dir "$FRITZ_DATA_DIR"
```

Use `--bin-dir dist/Fritz.app/Contents/Resources` to evaluate the staged release
binaries. Keep the failing quality result visible when comparing future model
pins or question designs; do not lower the gate to accept this model.
