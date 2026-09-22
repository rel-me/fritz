---
name: swiftui-pro
description: Review SwiftUI changes for correctness, state/task ownership, lifecycle, and performance. Use for code reviews or targeted diagnosis; ordinary SwiftUI reading and implementation do not require a review workflow.
license: MIT
metadata:
  author: Paul Hudson
  version: "1.1"
---

# SwiftUI review

Review the requested diff or feature within Fritz's existing architecture and
declared toolchain/deployment targets. Report actionable problems, with evidence
and practical impact. Do not apply iOS defaults to this macOS project, raise
platform targets, introduce dependencies, or reorganize unrelated code as a
side effect of review.

Start with the changed code and its callers. Load only references relevant to
the behavior being reviewed:

- [Data flow](references/data.md): ownership, bindings, observation, and state.
- [Views](references/views.md): composition, modifiers, and animation.
- [Navigation](references/navigation.md): selection, presentation, and navigation.
- [Performance](references/performance.md): identity, expensive work, and updates.
- [Swift](references/swift.md): error handling and data semantics.
- [Fritz concurrency](references/concurrency.md): cancellation, native boundaries,
  and stale responses.
- [API usage](references/api.md): investigate a suspected obsolete API, checking
  availability against Fritz's actual supported platforms before recommending it.
- [Hygiene](references/hygiene.md): scope, secrets, and verification.

For design or accessibility concerns, read only the relevant reference in
[macOS design guidance](../macos-design-guidelines/SKILL.md). Do not perform a
full HIG audit as part of every code review.

Treat platform-specific examples as examples, not reasons to change Fritz's
platform or architecture. For a focused review, do not load the entire reference
set or expand into a general HIG audit.

For each finding, give the file/line, triggering condition, resulting problem,
and the smallest useful correction. Include a code example only when needed to
explain the fix. Skip files without findings. State relevant verification and
uncertainty; do not manufacture findings to fill an output template.
