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

## User follow-up: download the binary input

> why commit binaries?
> I wonder if builds can download this file instead of having in repo

Replace the committed whatsapp.desc with a pinned upstream download verified by
its committed SHA-256. Prepare it explicitly into the shared download cache
before Cargo starts; keep Cargo code generation offline and preserve descriptor
freshness. Cache publication must be atomic and serialized per content hash.
Verify cached offline reuse, concurrent preparation, rejected corrupt/truncated
downloads, and unchanged generated output. Update PR #108, then monitor the new
head again, including all required checks and app builds. No bypasses or silent
recovery from corrupt cache entries; retain actionable errors and existing locks.

The pinned descriptor was fetched successfully and matched its committed hash.
Five downloader boundary tests passed: offline cache reuse without mtime change,
corrupt/truncated and oversized-response rejection, corrupt-cache actionable
failure without silent replacement, and cross-process atomic single-download
publication. Existing build-cache lock tests still pass with network work stubbed
outside their boundary. Cargo check after the downloaded-input change completed
in 26.74s, then 0.48s on the identical next invocation, preserving freshness.

## Concurrent main update

PR #106 merged pinned mise tooling while the descriptor-download follow-up was
being verified. Resolve the Makefile conflict by keeping mise's tool entry point
and the new prepare-rust-inputs target together. Preserve all auto-merged tool
setup changes, rerun setup/checks/build on the combined branch, push the merge,
and monitor the latest PR #108 head again.
