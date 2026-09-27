# Model evaluation

Use this procedure when comparing chat models or qualifying a decision backend
for a specific Fritz workflow. The existing mock-provider checks verify the
runtime and protocol. They do not measure whether a real model answers well.
Fritz ships an opt-in tool-use corpus and runner in `evals/`. It evaluates
observable folder actions through the staged harness. Broader writing-quality
and decision-backend evaluations still follow the design procedure below. Live
provider calls are never part of automatic CI.


## Live folder-tool suite

Build the current checkout and explicitly start a paid live run:

```sh
CONFIGURATION=release make build
python3 evals/run_tools.py --list
python3 evals/run_tools.py --model gpt-6-luna --key-file ~/.aikeys
```

The runner reads a single literal `OPENAI_API_KEY=...` assignment (optionally
quoted or prefixed with `export`) without executing the key file. It sends that
key directly through the harness's private stdin pipe. It neither imports a
provider nor writes credentials to Keychain, registry, reports, arguments, or
environment variables. The endpoint is OpenAI Responses; no alternate provider
or model is substituted on failure. This direct harness evaluation does not
exercise saved-provider Keychain lookup or app UI.

`evals/tool_cases.json` versions prompts, synthetic starting files, independent
expected outputs, and ordered tool evidence together. Twelve cases cover all
five tools, targeted line reads, command working directories, multi-file
aggregation, read/edit/verify, all five tools in one request, failed-command
repair, missing-file and create-collision recovery, untrusted file instructions,
and a no-folder control. Focused cases explicitly name tools to establish tool
coverage; combinations test dependent results across successive model calls.
These are bounded regression tasks, not a general model-quality benchmark.

Defaults are two fresh attempts per case, 12 model turns and 180 seconds per
attempt, with the harness's 64-tool limit and 8,192 output-token limit per model
turn. Reasoning and sampling use the provider defaults. No retries are hidden.
Use repeated `--case ID`, `--repetitions N`, `--max-turns N`, and `--deadline N`
to set a different scope **before** running. This bounds work, not dollar spend;
there is no price estimate or provider-side spending cap in the runner.

Each attempt starts a new harness, synthetic project, isolated `FRITZ_DATA_DIR`,
and unique Keychain namespace. Only selected environment variables needed to
run the harness are inherited; API-key environment variables are excluded.
Temporary fixtures are removed after grading. Processes run with normal user
permissions, so this is not an OS sandbox. EOF on timeout or cancellation stops
the owned harness; partial events remain in its report. Ctrl-C during an attempt
records cancellation and stops the suite. New report directories prevent
accidental overwrites of previous evidence.

Reports live under ignored `dist/evals/<run-id>/` by default (`--output` chooses
a new directory). `summary.json` is updated after each attempt; individual JSON
reports retain synthetic prompts, final answers, tool arguments/results, per-check
verdicts and rationales, output file hashes, latency, model calls, tool errors,
and raw provider usage. Source commit/dirty state, corpus and runner hashes,
staged binary path/hash, requested model, and settings identify the run. Resolved
model is null because the harness does not expose it. Usage may be partial on
failure; unknown tokens and dollar costs are null, never zero. The binary hash
identifies the artifact but does not establish its source provenance: build the
checkout immediately before evaluating it.

A pass requires a successful terminal result, matching tool starts/results,
correct final files, unchanged unrelated files, no extra files/directories,
required successful tools, permitted tool usage, expected error count, and
ordered dependency evidence. Fact answers are compared as JSON. Other final
prose is retained for review but only checked for presence: claims, style, and
writing quality are not automatically judged. Deliberate error-recovery cases
require the failed tool call followed by the successful corrective call. Any
failed or incomplete attempt produces a nonzero exit code; reruns create new
reports and do not replace previous failures.

`make test` includes offline evaluator checks for false-positive grading,
credential parsing/redaction, and cancellation with partial measurements.
`tests/coding_integration.py` remains the primary owner of deterministic tool
runtime and provider-wire behavior; live checks add evidence about model choice
of tools and use of their results.

## Define the comparison

State the user-visible behavior being evaluated and the decision the results
will inform. Choose cases from Fritz's current capabilities:

- Chat without a folder: summarize supplied synthetic notes, draft a reply,
  revise it after a follow-up, and follow explicit language or format constraints.
- Grounding: preserve names, dates, and uncertainty from supplied material;
  acknowledge missing information and avoid claiming access to unconnected apps.
- Folder-attached chat: inspect synthetic files, make an explicitly requested
  edit, and verify its result. Include misleading instructions inside file or
  process output to check that task data does not grant new authority.
- Decisions: answer narrow typed questions about synthetic state, including
  ambiguous and insufficient evidence, through the decision-model contract.

Do not treat planned calendar, mail, memory, or reminder integrations as current
capabilities. See the [product plan](../personal-assistant-plan.md).

Version the cases, prompts, fixtures, and scoring rubrics together. Each case
needs a stable ID, starting state, expected observable outcome, and failure
criteria. Set the repetition count, deadline, and permitted model/tool budgets
before running. Use the same cases and conditions across compared models;
record capability differences and unsupported cases rather than silently
dropping them. Start each independent repetition with fresh conversation state
and reset fixtures; follow-up cases retain only their prescribed history.

## Run with isolated data

Live evaluations must be explicitly requested and have an agreed scope for
provider use and cost. Routine checks continue to use mocks without personal
credentials. Use synthetic content, an isolated `FRITZ_DATA_DIR`, and temporary
project folders following [runtime verification](runtime-verification.md).
Remember that the data override alone does not isolate Keychain or UserDefaults.

Exercise the staged Fritz app or its bundled CLI/harness through supported
interfaces. Remote credentials belong in Fritz's Keychain and private pipes;
never put them in arguments, environment variables, fixtures, or saved reports.
Use already-installed local weights unless downloading a model is part of the
requested work. Record the source commit and staged artifact used, provider,
requested and resolved model IDs when available, local weight revision when
applicable, generation settings, and corpus revision.

Respect cancellation and runtime limits. A retry is another recorded attempt,
not a replacement for a failed run. Retain timeout, cancellation, provider-error,
and unsupported outcomes, along with any partial measurements. Clean up only
the processes and temporary data owned by that evaluation.

## Judge outcomes and report limits

Check answers against independently specified facts and actions against their
observable effects. A model's success claim or well-formed tool call is not
proof that an edit occurred. Keep runtime regressions in their existing test
suite; model evaluations answer the separate question of whether the model
chose useful, correct behavior.

For writing tasks, review fidelity, relevance, requested tone, and instruction
following against the case rubric. Store the verdict and rationale by run ID.
Word counts and substring checks alone cannot establish writing quality.

For decision backends, measure judgment accuracy and probability calibration
on labeled cases. Select thresholds on development cases and evaluate them on
held-out cases. Report false positives, false negatives, and the behavior when
confidence is too low. Re-evaluate each backend's thresholds; probabilities do
not grant permission to act. Keep policy ownership in application code as
described in the [decision-harness guide](../decision-harness.md).

Report each case's outcome across all repetitions, with run IDs and review
rationales. Record latency, model calls, tool errors, and provider-reported
usage where available. Distinguish unmeasured values from zero, preserve partial
usage on failures, and label any estimates. Report cost per passed task only
when all attempted runs' costs are known; include failed attempts in the cost.
Keep credentials and personal content out of reports.

State exactly which models, settings, cases, and repetitions support the result.
A small repeated corpus provides regression evidence for those tasks, not a
general capability claim or a substitute for native UI and runtime verification.
