# Scope and verification

Keep credentials out of source, logs, snapshots, and UI persistence. Follow Fritz's
Rust/Keychain ownership contract and existing error-reporting paths.

Select checks that exercise the changed behavior. Runtime changes require the
root staged-app workflow; visual changes require affected UI checks.
Neither unit tests nor previews replace those requirements. Prefer deterministic
fixtures for ordering and cancellation over sleeps or repeated trial runs.

Review comments where a non-obvious ownership or compatibility invariant changes.
Do not add translation work, dependencies, lint tools, global skills, or a new test
harness as a side effect of code review. Report unverified behavior explicitly.
