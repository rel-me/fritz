# Update all libraries

## User request

> Update all libraries..

## Delegated prompt

> Monitor the dependency update pull request through its final GitHub checks. Diagnose and fix failures caused by this branch, run the relevant local checks, commit and push any fixes, and keep monitoring the latest head until checks conclude. Coordinate with me before changing files while local verification is in progress. Report the final check outcomes and any external blocker.

## Follow-up prompt

> Fix the two test compatibility errors found in CI: use `ToolName::new` in `tests/public_api.rs` and read SQLite `usize`-sized counts as `i64` in `tests/state.rs`. Run `make check`, commit and push the fix, then monitor the updated PR through terminal success.

> Adapt the WhatsApp integration to the updated upstream APIs on existing paths. Preserve the Keychain data shape and atomic app-sync patch commit, linked-device ready-state semantics, and graceful bounded shutdown. Use upstream in-memory reference behavior for `commit_patch`; add synthetic tests only. Run `make check` and let me know before I restart local verification.
