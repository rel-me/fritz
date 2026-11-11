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

Fritz uses a local Cargo patch at `vendor/waproto`, based on the existing WhatsApp
pin, with only that generator repair. See its [provenance and update procedure](../../vendor/waproto/FRITZ.md).
The runtime/protocol sources and original tests match the pinned upstream bytes;
all locked dependency versions remain unchanged. Updating the entire upstream
pin would pull in 202 unrelated commits, including breaking API changes.

The patched isolated check sequence took 29.45 s, 0.49 s, and 0.26 s. Generated
`whatsapp.rs`, `tags.rs`, and `whatsapp.local.desc` hashes matched the original
producer. These measurements establish removal of the extra first incremental
rebuild; they do not claim improvement to the already-fresh steady-state cycle.

The owning regression in `tests/waproto_descriptor.rs` checks unchanged-output
reuse, repair of old cached timestamps, encoded-content changes, and preservation
of future source timestamps. It failed the original producer before the fix.
`make test` runs it with the existing root Rust tests.

## Full-sequence verification after repair

The unchanged CI recipe was run twice with the repaired package, retaining its
normal Cargo/Clippy checks and output lock:

| Stage | First cycle with new package | Settled warm cycle |
| --- | ---: | ---: |
| `make ci-prepare-runtime` | 122.873 s | 3.537 s |
| Test compilation handoff (`--no-run`) | 0.764 s | 0.457 s |
| `cargo build --locked` | 0.416 s | 0.357 s |

The first cycle compiled the newly selected local package in test and Clippy
modes. Neither execution handoff compiled waproto or its integration consumers.
The second cycle remained fresh. This verifies the handoff repair without
changing the existing commands, disabling Clippy, or suppressing Cargo checks.
