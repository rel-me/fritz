# Fix repeated Rust compilation on warm outputs

## User request

> Investigate and fix the repeated Rust compilation next. Confirm it on warm outputs first. Update origin and do it in a new PR.

Fetched origin and created a new branch from updated origin/main (01c6e29),
including merged PR #107. First reproduce the preparation/execution compilation
sequence on unchanged warm outputs and capture Cargo fingerprint reasons. Keep
verification under the build-cache wrapper and preserve all existing checks.

## Delegated monitoring prompt

Monitor the new PR at its latest pushed head until both required checks and both
app builds finish. Verify repeated Rust compilation is fixed without reducing
coverage or skipping Cargo freshness checks. Inspect failures and coordinate
with the parent before editing; preserve unrelated changes and account/output
locking. Do not merge. Monitor any corrected head again and report exact head,
check results, Cargo preparation/execution timings, and remaining blockers.
Append substantive follow-up delegated prompts to this file.

## Investigation outcome and focused repair

Two unchanged, fully warmed preparation/execution cycles were already fresh
(test preparation 2.854/1.344s; execution compile checks 0.426/0.423s). A fresh
isolated waproto check then an identical incremental check reproduced 34.11s,
21.92s, then 0.40s; Cargo traced the extra compilation to the generated
whatsapp.local.desc being newer than its build-script invocation. Reordering
CI preparation still left a 61.099s test handoff rebuild and was rejected.

Backport only the upstream waproto producer repair from 8e171946 into a local
snapshot of the existing 3a08e84e pin. Do not upgrade the surrounding 202 upstream
commits or change runtime/protocol code. Normalize inherited manifest settings,
preserve license/provenance, and retain Cargo source/future-timestamp tracking.
The filesystem regression failed the original producer and passed the repair.
Patched incremental checks were 29.45s, 0.49s, 0.26s; generated code/tag/descriptor
hashes matched the original implementation. Verify the full CI sequence and
monitor the new PR, confirming no waproto recompilation during execution.
