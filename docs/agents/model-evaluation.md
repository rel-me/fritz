# Model evaluation

Use this procedure when comparing chat models or qualifying a decision backend
for a specific Fritz workflow. The existing mock-provider checks verify the
runtime and protocol. They do not measure whether a real model answers well.
Fritz does not yet ship a versioned model-quality corpus or evaluation runner;
this document defines how to design and report that work, without implying a
new command or automatic evaluation in CI.

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
