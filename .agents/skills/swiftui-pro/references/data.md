# State ownership and bindings

Identify the existing source of truth and its consumers before suggesting a
wrapper or model change. UI-owned state, transport state, and persisted records
have different lifetimes. Do not mandate an observation framework migration.

- Check that view recreation does not reset user edits or duplicate service work.
- Trace bindings through validation, persistence, and side effects. A computed
  binding is valid when it expresses the required translation; report a bug only
  when its getter/setter loses updates, loops, or violates the ownership contract.
- After deletion, filtering, or session changes, verify selection still refers
  to a valid record. Stable IDs should describe record identity, not row position.
- Treat derived-state caching as an invalidation problem: which source changes
  refresh it, and can asynchronous results overwrite newer state?
- Follow existing persistence services. Do not introduce another storage layer
  or move credentials into view state/UserDefaults to simplify a binding.

For work crossing isolation boundaries, read [Fritz concurrency](concurrency.md).
