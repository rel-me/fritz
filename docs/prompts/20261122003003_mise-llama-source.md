# Move llama.cpp source management to mise

## User requests

> why is&#x20;
> modified:   vendor/llama.cpp
>
> this keeps happening

> Can we have mise handle this instead of submodule?

## Delegated prompt

> Monitor the open PR for branch codex/mise-llama-source in rel-me/fritz until its checks reach a terminal state. If a failure is caused by this change, diagnose it, fix it on the PR branch in an isolated worktree, run focused verification, commit and push, and monitor the new head until it passes. Report the final head and check results, and distinguish unrelated failures or infrastructure blockers. Do not merge.
