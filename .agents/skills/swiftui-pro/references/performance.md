# Performance review

Report an expensive path with its trigger, frequency, and input size. Use a
measurement or a concrete repeated-work path; syntax alone is not evidence of a
performance defect.

- Check synchronous I/O, decoding, filtering, or formatting on UI isolation.
- Trace repeated construction of native views, services, and observers through
  view updates. Preserve stable identity where state must survive.
- For large collections, assess realized rows and update cost before changing
  container types. Small eager stacks do not need automatic replacement.
- If caching is warranted, define invalidation and bound retained data. Do not
  hide stale-state bugs behind a cache.
- A task modifier can tie work to view lifetime, but cancellation is cooperative.
  Verify the operation and its child/unstructured tasks actually stop, and late
  completions cannot overwrite a newer request.

Use [Fritz concurrency](concurrency.md) for actor ownership and request lifetime.
Do not turn a review into a broad profiling run without a relevant symptom.
