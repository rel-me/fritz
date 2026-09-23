# Fritz concurrency review

Use this reference for state/task review in Fritz. For compiler diagnostics or
language migration, use the repository-owned
[concurrency skill](../../swift-concurrency/SKILL.md) and its relevant topic.
An observable type does not by itself establish actor ownership.

## Trace ownership at the boundary

- `app/Sources/Fritz/Services/AgentClient.swift` owns the bundled process and
  pending continuations on the main actor. A detached reader frames stdout;
  generation tokens reject callbacks from a previous process. Trace startup,
  stop/restart, EOF, cancellation, and continuation cleanup.
- `app/Sources/Fritz/Stores/ChatStore.swift` owns a thread's transcript and
  generation task. Switching the selected thread must not redirect streamed
  output or cancellation to a different thread.
- `app/Sources/Fritz/Stores/ProviderStore.swift` owns provider discovery and
  saved connection updates. Check which request owns loading, results, errors,
  and cleanup when the user changes selection or cancels an editor.
- `app/Sources/Fritz/Stores/WorkspaceStore.swift` owns projects, thread
  selection, and cached chat stores. Preserve independent drafts/model settings
  and active request ownership when creating, switching, or restoring threads.
- `src/main.rs` routes request IDs and cancellation to Rust provider operations.
  Swift cancellation must reach this transport rather than merely hide output.

## Review a concrete interleaving

Write the smallest relevant sequence: request A starts, selection changes,
request B starts, then A completes or fails. Check loading, result, error, and
cleanup ownership on both success and error paths, including defer. Actor
isolation does not make state assumptions survive suspension.

Trace cancellation from the request owner through the private pipe and network
operation. Pending continuations must finish once, including process failure
and restart. Check native main-thread requirements separately from Swift actor
annotations; keep blocking pipe reads off the UI actor.

For validation, inspect `app/Tests/FritzTests/WorkspaceTests.swift` and
`tests/integration.py`. Add controlled completion-order coverage when changing
these behaviors; avoid sleeps as proof that stale callbacks cannot occur.
Follow root runtime verification when changing executable code.
