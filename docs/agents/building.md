# Building Fritz

[Back to README](../../README.md)

## Build and run

Requires macOS 15+, full Xcode with Swift 6.3+, and mise. `mise.toml` is the
source of truth for Rust (including rustfmt and Clippy), Python, CMake, Node/npm,
XcodeGen, GitHub CLI, and sccache. `make setup` trusts the configuration and
installs these versions before resolving dependencies; no preinstalled Cargo,
Python, CMake, or Node is required. Xcode supplies Swift, Apple SDKs, signing,
and packaging tools; macOS supplies Make, Git, and system utilities.

Make targets use `mise exec`, so shell activation is optional. For direct commands,
use `mise exec -- COMMAND` (for example, `mise exec -- cargo --version`), or
activate mise in your shell. CI installs the same tools before toolchain checks.
Node includes npm; website dependencies such as Wrangler stay in
`website/package-lock.json` and are installed with `mise exec -- npm --prefix website ci`.

```sh
make setup     # check tools and resolve committed dependency versions
make dev-open
```

## Staged apps

`make dev-open` builds and opens `dist/FritzWebViewDebug.app` in the primary repository
checkout on any branch, or on `main` in a linked worktree, without a PR lookup. Other
linked branches use `dist/FritzWebViewDebug{PR number}.app` when GitHub CLI can resolve a PR;
linked branches without a resolvable PR and all detached checkouts use
`dist/FritzWebViewDebug{checkout hash}.app`. The checkout-path hash still gives each Debug app
a separate bundle ID, data directory, Keychain service, and UserDefaults domain. Debug
builds have no update feed. `CONFIGURATION=release make build` stages the optimized
`dist/Fritz.app`; neither command installs to `/Applications`. Both bundles include the
Rust agent and Markdown resources and are locally signed by default.

`make release-build` (also `CONFIGURATION=release make build`) stages the optimized app
at the current source version without selecting a release version, installing,
launching, notarizing, packaging, or publishing. Rust and Xcode compile concurrently,
with full logs in `dist/build-logs/`. Local Swift builds use only the host architecture;
distribution keeps its existing architecture settings and always stages a fresh
artifact.

## Build caches

`make setup` installs the tool versions pinned in `mise.toml`. Compiler caches and immutable
native Metal libraries live under `~/Builds/Machine/Fritz/compiler-cache/`. Unchanged
local builds reuse the signed app after checking source bytes, build settings, toolchain
identity, bundled file hashes, and signatures. No compiler daemon starts on a reuse hit.
Delete `dist/.build-reuse-release.json` or `dist/.build-reuse-debug.json` to force that
configuration to compile and stage.

Build storage lives under `~/Builds/Machine/Fritz` by default. Main and worktrees reuse
Cargo outputs and Swift/Xcode package caches; SwiftPM scratch directories and Xcode
DerivedData have separate subdirectories per checkout. Builds and tests serialize access
to shared compiled outputs through tests and app staging. `make setup` locks only its
checkout, so another worktree's build does not delay dependency setup. Package managers
still coordinate their download caches. Set `FRITZ_BUILD_ROOT=/absolute/path` to use a
different location. Existing checkout-local build folders are left untouched and can be
removed once no old builds are using them. Use `mise exec -- python3 scripts/build-cache.py COMMAND
...` for direct Cargo commands or integration scripts that need the same paths and lock.
`make setup`, Rust checks/tests, and app builds prepare the pinned Protobuf
descriptor in the shared download cache. `make prepare-rust-inputs` prepares it
explicitly. The download uses an immutable revision and a committed SHA-256;
verified cache hits work offline without touching timestamps. Cargo codegen
only reads the prepared input. See [descriptor provenance and recovery](../../vendor/waproto/FRITZ.md#downloaded-descriptor).

See [build storage details](runtime-verification.md#build-storage).

## Xcode project

The native Xcode project is `app/Fritz.xcodeproj`; its source specification is
`app/project.yml`. Regenerate project structure with `mise exec -- xcodegen generate --spec
app/project.yml`. Use the Makefile to stage the complete app with its Rust agent.
`app/Package.swift` supports fast Swift builds and unit tests.

## Verification

```sh
make test
make check
```

Tests cover stream framing, adapter payloads, model selection, provider categories,
independent thread persistence, previous-chat recovery, persistence failures,
local-model integrity and cancellation, action parsing/history, file boundaries, atomic
changes, process output/timeouts, and the real CLI/agent/harness against local
deterministic providers. The decision-harness check uses local Jev and OpenAI Decisions
endpoints and a dummy key to verify typed answers and cancellation. End-to-end action
tests cover all six chat adapters, interrupted streams, recovery, limits, and child
process cancellation. They do not download weights, require personal API keys, or
contact paid services. Real provider credentials are required to validate
account-specific model availability and usage limits.

For shared UI visual regression checks, run `make check-ui-snapshots`. See [UI
verification](ui-verification.md) for coverage and reference review.

## Development guidance

The Codex environment in
[.codex/environments/environment.toml](../../.codex/environments/environment.toml)
provides worktree setup and Run Fritz, Build, Test, and Check actions.
[AGENTS.md](../../AGENTS.md) documents the architecture and development rules. The
repository includes [development skills](skills.md) for SwiftUI implementation/review,
macOS design, concurrency, builds/AppKit, and test audits. See [runtime
verification](runtime-verification.md) and [UI verification](ui-verification.md) for
local testing, and [model evaluation](model-evaluation.md) for model-quality
comparisons.

## Live tool evaluations

The opt-in [tool evaluation suite](model-evaluation.md#live-folder-tool-suite) checks
all five folder tools and multi-step tasks against actual file outcomes. After
`CONFIGURATION=release make build`, run `python3 evals/run_tools.py --model gpt-6-luna
--key-file ~/.aikeys`. The key file must contain a literal `OPENAI_API_KEY` assignment;
the runner does not source it. Defaults are 12 synthetic cases with two repetitions,
with reports under `dist/evals/`. This makes paid API requests; normal `make test` stays
offline.
