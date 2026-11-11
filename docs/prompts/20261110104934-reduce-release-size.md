# User requests

> why is fritz release dmg 152MB?

> Reduce the duplicated inference code and strip unnecessary symbols so the release DMG is smaller.

# Delegated prompts

Monitor the open PR for branch codex/gabriel/reduce-release-size until all required checks complete. Fix failures caused by this change, run appropriate local checks, commit and push any fixes, and monitor the new head again. Preserve unrelated changes and do not merge. Follow AGENTS.md, including appending any delegated follow-up prompts to docs/prompts/20261110104934-reduce-release-size.md. Report the PR URL, head commit, check results, and exact blockers.

# Follow-up user requests

> re-evaluate what things are big show me where that is

> Can we shrink the 49.5 MiB Metal quantization library by only including the kernels Fritz actually uses?

> is there an alternative to mistral.rs which is smaller in this way already?

> Build a minimal llama.cpp runtime and measure its size against mistral.rs before we decide whether to switch.

# Delegated prompt: measurement follow-up CI

Monitor the open PR for branch codex/gabriel/reduce-release-size until all required checks complete. Fix failures caused by this change, run appropriate local checks, commit and push any fixes, and monitor the new head again. Preserve unrelated changes and do not merge. Follow AGENTS.md, including appending any delegated follow-up prompts to docs/prompts/20261110104934-reduce-release-size.md. Report the PR URL, head commit, check results, and exact blockers.

# Follow-up user request for runtime testing

> Test llama.cpp with Fritz’s GGUF chat models and Bosun, and compare startup time and generation speed with mistral.rs before we decide whether to switch.

# Delegated prompt for benchmark report CI

Monitor the open PR for branch codex/gabriel/reduce-release-size until all required checks complete. Fix failures caused by this change, run appropriate local checks, commit and push any fixes, and monitor the new head again. Preserve unrelated changes and do not merge. Follow AGENTS.md, including appending any delegated follow-up prompts to docs/prompts/20261110104934-reduce-release-size.md. Report the PR URL, head commit, check results, and exact blockers.

# Follow-up user request for readable documentation

> Report this perf test in a doc in docs/...

# Delegated prompt for documentation CI

Monitor PR #102 after the readable performance report is pushed. Check the latest head, fix failures caused by this documentation change, commit and push any fixes, and monitor each changed head again. Preserve unrelated changes and do not merge. Report checks and exact blockers.

# Follow-up user requests for history cleanup

> oh oops .. this PR was **+23,404?  Can we prune that and force update the repo to remove that history.. too big of a data chnage**

> you'll have to prune the data from master since its merged

# Delegated prompt for rewritten main verification

Verify the rewritten origin/main and the cleaned PR branch after the benchmark data is pruned from history. Monitor CI for the rewritten main head through completion, fix failures caused by this cleanup, and recheck any updated head. Preserve unrelated changes. Report the exact head, checks, and blockers.

# Follow-up user request for backend replacement

> Replace mistral.rs with llama.cpp for Fritz’s local chat models and Bosun, preserving streaming, tool calls, cancellation, and decision behavior. Build and measure the final app and DMG.

### Migration test ownership

The obsolete `raw_readout_masks_unused_slots_and_uses_final_prompt_position`
unit test exercised Mistral tensor chunk extraction. That production path no
longer exists: the bridge requests the last llama.cpp logit row and copies the
eligible contiguous slots. The existing opt-in native Bosun probability test
and real decision-harness fixture comparisons own the replacement contract.
Removed `tests/test_metal_cache.py` with its exclusively Mistral-specific
xcrun wrapper/cache and Make consumer; its eight tests guarded an unused build
adapter, not the new embedded-shader CMake build.

The existing app-reuse CLI suite now covers a tracked native gitlink: a signed
bundle can be reused with identical submodule sources, and a submodule source
edit invalidates reuse. This guards reuse of stale native code, which ordinary
root-file invalidation did not cover; no production-only testing seam was added.

Setup now initializes the pinned submodule. The existing setup lock-routing test
initializes its two temporary checkout fixtures as real Git repositories; it had
failed because those previously only contained copied setup scripts. This keeps
the real Git command and the existing cross-checkout concurrency assertions.

### Delegated prompt: final PR monitoring

Monitor the new llama.cpp migration PR for branch
`codex/gabriel/llama-local-runtime` at the final pushed head. Wait for all CI checks and inspect actionable review
failures. Fix failures caused by this change on the existing branch, run the
affected local checks through the build-cache wrapper, commit and push fixes,
and monitor the new head again. Preserve unrelated changes. Log any delegated
follow-up requests in this prompt file. Report the exact checked head, checks,
fixes and blockers. Do not merge or publish a release.

A two-directory Cargo probe confirmed that identical package names share
`OUT_DIR` under a common target directory, despite different source checkout
paths. The native CMake subtree now includes a hash of checkout path and compiler
environment, preventing stale absolute CMake source/compiler paths across
Fritz worktrees. Native compilation and the staged build verify this path.

PR #102 merged while this migration was being verified. The migration is now
on a new branch based on current main; the only conflict was this prompt log.

### Delegated prompt: PR #104 CI

Monitor PR https://github.com/rel-me/fritz/pull/104 on
`codex/gabriel/llama-local-runtime`. The code is pushed at f217439; a documentation
commit with final measurement receipts will follow shortly. Follow each new head
until all CI checks complete and inspect actionable review failures. Fix failures
caused by this change on this branch, run affected local checks through the build
cache wrapper, commit and push fixes, and monitor the updated head again. Preserve
unrelated changes. Log delegated follow-up requests in this prompt file. Report
the exact checked head, checks, fixes and blockers. Do not merge or publish a
release. The previous PR #102 is merged and is no longer the target.
