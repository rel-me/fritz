---
name: swift-concurrency
description: Diagnose Swift concurrency errors, implement async/await and actor boundaries, manage task lifetime and cancellation, or guide a requested Swift migration in Fritz. Use for concurrency work, not every Swift edit.
license: MIT
metadata:
  author: Antoine van der Lee
  source: AvdLee/Swift-Concurrency-Agent-Skill
  revision: 45fa49e4e0b2af4d43b1cb458903f8030ac993bd
---

# Swift concurrency in Fritz

Inspect the affected target's Package.swift, build settings, and nearby state
owner. Confirm the language mode, strict concurrency level, default isolation,
and enabled upcoming features before choosing syntax. A tools-version header
alone does not establish language mode. Preserve Fritz's declared toolchain and
platform; migration advice does not authorize changing them.

Capture the actual diagnostic when fixing an error. Identify which actor owns
the state, which values cross isolation boundaries, and who owns each task's
lifetime. Prefer the smallest change that preserves that ownership. Use
structured concurrency for bounded child work. For unstructured tasks, make
cancellation, retained handles, and stale-result handling explicit.

Keep UI-owned state on the main actor; do not apply MainActor to unrelated work
to silence diagnostics. An await is a potential suspension point, not proof that
work leaves the main actor. Recheck state assumptions after suspension because
actors are reentrant. Move expensive synchronous work off UI isolation through
an API supported by the target's compiler. Do not introduce detached tasks or
new concurrency syntax solely because an example uses them.

Use Sendable values at boundaries where possible. Any unchecked Sendable,
preconcurrency, or unsafe nonisolated escape hatch needs a concrete, documented
safety invariant. Preserve AppKit main-thread requirements and pipe-reader
callback ownership; Swift actor isolation does not replace process and
transport lifetime handling.

For a Fritz UI/request-lifetime review, start with the focused
[ownership and cancellation examples](../swiftui-pro/references/concurrency.md).
Load the deeper references below only for the specific language/runtime question.

Load only the reference needed for the task:

- [Async/await](references/async-await-basics.md): callback conversion and continuations.
- [Tasks](references/tasks.md): cancellation, task groups, and lifetime ownership.
- [Actors](references/actors.md): isolation, reentrancy, and executors.
- [Sendable](references/sendable.md): safe transfer across isolation boundaries.
- [Threading](references/threading.md): execution and version-dependent isolation.
- [Streams](references/async-sequences.md): AsyncSequence and AsyncStream cleanup.
- [Async algorithms](references/async-algorithms.md): stream composition when needed.
- [Memory](references/memory-management.md): task retention and deallocation.
- [Observation](references/observation.md): observable UI state and isolation.
- [Testing](references/testing.md): deterministic async verification using the existing harness.
- [Performance](references/performance.md): measurements of actor hops and expensive work.
- [Migration](references/migration.md): explicitly requested language migrations.
- [Linting](references/linting.md): concurrency diagnostics from existing tooling.
- [Core Data](references/core-data.md): only when the affected code uses Core Data.
- [Glossary](references/glossary.md): terminology.

The bundled upstream references include examples for other Apple platforms and
newer Swift versions. Adapt them to the verified target settings and Fritz's
existing dependencies; they do not require new frameworks, packages, test
harnesses, or architecture. In particular, a task group waits for its children
on normal scope exit; cancellation is cooperative. Check the actual group API
and error path before relying on automatic cancellation.

Follow [runtime verification](../../../docs/agents/runtime-verification.md) for
runtime edits and [UI verification](../../../docs/agents/ui-verification.md)
for affected UI. Verify the relevant cancellation, lifetime, ordering, and error
behavior. Use the repository's build and test entry points when upstream
references show generic Swift or Xcode commands.
