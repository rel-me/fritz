# Move llama.cpp source management to mise

## User requests

> why is&#x20;
> modified:   vendor/llama.cpp
>
> this keeps happening

> Can we have mise handle this instead of submodule?

## Delegated prompt

> Monitor the open PR for branch codex/mise-llama-source in rel-me/fritz until its checks reach a terminal state. If a failure is caused by this change, diagnose it, fix it on the PR branch in an isolated worktree, run focused verification, commit and push, and monitor the new head until it passes. Report the final head and check results, and distinguish unrelated failures or infrastructure blockers. Do not merge.

> Local make check and make test passed. Local Xcode 27.2/Swift 6.4.2 failed the locked setup and stage at SwiftPM resolution because the unchanged lock references xctest-dynamic-overlay and the resolver now selects swift-issue-reporting. If CI hits the same, compare main and report it as a pre-existing Swift graph issue. Leave Swift locks unchanged unless CI evidence links the failure to this PR.

> Continue monitoring PR #156 on its latest head, which adds the delegated prompt log. Report the terminal result for that head.
