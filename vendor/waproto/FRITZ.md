# Pinned waproto build-freshness backport

This is `waproto` 0.7.0 from the same WhatsApp revision Fritz already uses:
[3a08e84e8d7a462f6f87eb98d28fe1ce889a653a](https://github.com/oxidezap/whatsapp-rust/tree/3a08e84e8d7a462f6f87eb98d28fe1ce889a653a/waproto).
`LICENSE` contains the upstream MIT license. Source/protocol files and the
original serde tests are copied byte-for-byte. `Cargo.toml` expands upstream
workspace-inherited dependency/lint settings without changing their values;
`clippy.toml` is copied from that revision's workspace root.

The only generator behavior change backports the descriptor timestamp repair
from upstream [8e17194669c755b876cf29fdc30a6dfa474b5914](https://github.com/oxidezap/whatsapp-rust/commit/8e17194669c755b876cf29fdc30a6dfa474b5914):

- `build.rs` calls `build/descriptor.rs` and tracks that helper as an input.
- The helper preserves content-based writes and dates the generated descriptor
  like `src/whatsapp.desc`, including repairs to existing cached timestamps.
- Real schema, build-script, helper, and future-source timestamp changes still
  invalidate the build through Cargo's normal input tracking.

The pinned generator writes `OUT_DIR/whatsapp.local.desc`; buffa-build registers
that generated file as an input. Its initial current-time timestamp is newer
than Cargo's build-script start, which makes the first incremental invocation
rerun codegen and recompile its consumers. Dating the derived descriptor like
its actual source fixes the producer instead of changing Cargo fingerprints or
skipping freshness checks.

The upstream fix is 202 commits after Fritz's pin, including unrelated breaking
API changes. This local Cargo patch retains the current runtime/protocol API.
When updating the WhatsApp pin, replace this snapshot from that exact revision
and reapply only the build fix if still needed. Once the pinned upstream includes
the repair, remove this directory, the Cargo patch/exclusion, and the local
`tests/waproto_descriptor.rs` helper regression together.

The owning regression is `tests/waproto_descriptor.rs`, run by `make test`.
It verifies unchanged-output reuse, cached timestamp repair, encoded changes,
and preservation of future source timestamps. It failed against the original
write-if-changed producer before applying the repair.
