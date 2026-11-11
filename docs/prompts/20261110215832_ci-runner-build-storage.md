# Isolate CI build outputs per runner

## User request

> Tackle the shared-cache contention next. Keep shared download and compiler caches, but isolate writable build outputs per runner.
> In new PR. (after update origin)

Fetched origin and created a new branch from updated origin/main, including merged
PR #105. Preserve local default storage behavior, dedicated CI account/session
locking, and existing checks. Commit, push, and open a new ready PR.

## Delegated monitoring prompt

Monitor the new PR at its latest pushed head until every required check and both
app-build checks finish. Verify CI uses separate runner build roots and retains
the shared package/compiler cache root. Investigate failures and coordinate
with the parent before edits. Preserve unrelated changes, account/session
isolation, and output locks through tests/staging. Do not merge or skip coverage.
If fixes are pushed, monitor the new head again. Report exact head, check results,
timings, and remaining blockers. Append substantive follow-up prompts here.
