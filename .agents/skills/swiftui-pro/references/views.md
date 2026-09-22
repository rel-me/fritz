# View identity and lifecycle

Review the changed component together with its state owner and consuming views.
Look for identity changes that reset focus, drafts, selection, or native view
instances. Verify representable updates are idempotent and teardown releases
observers, delegates, and callbacks owned by the component.

Extract a subview when it improves ownership, reuse, or update behavior for the
actual change. Small private view helpers and multiple tightly related types in
one file are not findings by themselves. Avoid imposing a new folder structure
or view-model layer during a focused review.

Check animation triggers and completion behavior against the interaction:
interrupted animations and repeated activation should leave consistent state.
Do not substitute timing guesses for a completion contract. Preserve existing
native controls and text-editing semantics unless the requested behavior needs
another control. For design and accessibility conventions, consult only the
relevant reference in the local macOS design skill.
