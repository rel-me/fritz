# Cargo preparation freshness

The investigation on 2026-11-11 distinguished fully settled output reuse from
an avoidable first incremental rebuild. All commands ran through
`scripts/build-cache.py`; each measured sequence held one output lock so another
checkout could not change the artifacts between invocations. Cargo fingerprint
tracing identified inputs; no source files or timestamps were altered between
measurement steps.

## Original behavior

Two unchanged preparation/execution cycles on the existing warm output tree
were already fast:

| Stage | First cycle | Second cycle |
| --- | ---: | ---: |
| `make ci-prepare-runtime` | 2.854 s | 1.344 s |
| `cargo test --workspace --all-features --locked --no-run` | 0.426 s | 0.423 s |
| `cargo build --locked` | 0.314 s | 0.313 s |

An isolated `cargo check -p waproto --locked` sequence then reproduced the
avoidable rebuild: 34.11 s for initial compilation, 21.92 s for the next identical
invocation, and 0.40 s for the third. The second invocation had compiled outputs,
but Cargo reported `whatsapp.local.desc` newer than the build-script run and
recompiled waproto. Its consumers inherit the invalidation.

Trying Clippy first, then binary compilation, then test preparation did not fix
the producer: the first test handoff still rebuilt for 61.099 s; a later fully
settled handoff took 0.482 s. The Make recipe order was left unchanged.

## Producer repair

The pinned waproto generator creates `OUT_DIR/whatsapp.local.desc`, and
buffa-build registers that generated file as a source input. Its first current-time
write is later than Cargo's build-script start. Preserve its real source's
timestamp after content-based writes, as in upstream's
[build-freshness repair](https://github.com/oxidezap/whatsapp-rust/commit/8e17194669c755b876cf29fdc30a6dfa474b5914).
This keeps the generated input fresh without changing Cargo fingerprints,
skipping checks, or hiding real source/build-script changes. Future source
timestamps remain visible to Cargo too.

Fritz patches only `waproto` to the immutable fork commit
[`f23447d8`](https://github.com/rel-me/whatsapp-rust/commit/f23447d871e75853c94869a80b764e0107607a13),
a backport of upstream's repair onto the exact existing WhatsApp revision
`3a08e84e8d7a462f6f87eb98d28fe1ce889a653a`. Only the build script, its helper,
and the two upstream regressions differ from that revision. Runtime, schema,
descriptor bytes, and dependency versions are unchanged. Cargo downloads and
caches the pinned dependency normally; Fritz has no vendored crate, descriptor
downloader, or extra preparation steps. Existing shared package/compiler caches
and per-runner build outputs remain unchanged.

The full upstream update would pull in 202 unrelated commits, including breaking
API changes. When Fritz's WhatsApp pin includes upstream fix `8e171946`, remove
the `waproto` Cargo patch and regenerate the lockfile. Until then, retain the
immutable fork commit rather than tracking its branch.

The patched isolated check sequence took 29.45 s, 0.49 s, and 0.26 s. Generated
`whatsapp.rs`, `tags.rs`, and `whatsapp.local.desc` hashes matched the original
producer. These measurements establish removal of the extra first incremental
rebuild; they do not claim improvement to the already-fresh steady-state cycle.

The owning upstream regressions are `waproto/tests/descriptor_cache.rs`
(timestamp/content behavior) and `waproto/tests/build_freshness.rs` (the actual
generated descriptor against Cargo's build-script start). Run them explicitly
from a checkout of the pinned fork with `cargo test --manifest-path
/path/to/whatsapp-rust/Cargo.toml -p waproto --test descriptor_cache --test
build_freshness --locked` through Fritz's build-cache wrapper. Workspace tests
do not execute tests owned by Git dependencies. The timestamp regression fails
the original producer.

## Full-sequence verification after repair

The unchanged CI recipe was run twice with the repaired package, retaining its
normal Cargo/Clippy checks and output lock:

| Stage | First cycle with new package | Settled warm cycle |
| --- | ---: | ---: |
| `make ci-prepare-runtime` | 122.873 s | 3.537 s |
| Test compilation handoff (`--no-run`) | 0.764 s | 0.457 s |
| `cargo build --locked` | 0.416 s | 0.357 s |

These pre-fork measurements compiled the newly selected local package in test
and Clippy modes. Neither execution handoff compiled waproto or its integration consumers.
The second cycle remained fresh. This verifies the handoff repair without
changing the existing commands, disabling Clippy, or suppressing Cargo checks.

## Pinned-fork verification

With the pinned fork, the first standalone check took 24.154s and the identical
next check 0.601s. Normal CI Rust preparation then took 1.913s, followed by a
0.473s test compilation handoff and 0.475s binary handoff. The second check,
preparation, and both handoffs had zero `Compiling` lines. All commands used
one wrapper-held output lock with no edits between measurements.

Both owning regressions pass from the fork checkout; the timestamp regression
fails against the original write-if-changed producer. Generated Rust, tags, and
descriptor hashes match the previous implementation across ten output variants.
Fritz's `make check` and full snapshot-enabled `make -j2 test` pass with this pin.
