# Runtime verification

`make setup` prepares dependencies using the committed Cargo and Swift package
locks and initializes the pinned `vendor/llama.cpp` Git submodule. It needs full
Xcode with Swift 6.3+ and mise. Setup trusts `mise.toml` and installs its pinned
Rust (with rustfmt and Clippy), Python, CMake, Node/npm, XcodeGen, GitHub CLI,
and sccache before resolving dependencies. Swift, SDKs, and Apple platform tools
come from Xcode/macOS. Setup does not change Git branches, copy local credentials,
build an app, or launch one. Make targets enter the mise environment automatically;
prefix direct tool commands below with `mise exec --` unless your shell has mise
activated. XcodeGen is used when regenerating `app/Fritz.xcodeproj`.

The [Codex environment](../../.codex/environments/environment.toml)
defines Fritz's local setup and actions. Setup runs `make setup`; the toolbar actions
invoke the existing Make targets. See the [official local-environment documentation](https://learn.chatgpt.com/docs/environments/local-environment)
for setup and action behavior.

## Checks and staged artifact

For runtime changes:

```sh
make test
make check
CONFIGURATION=release make build
```

`make test` runs Rust tests, root Swift-library tests, app Swift tests, and the real CLI/agent integration
harness. The harness starts `tests/mock_provider.py` on a free loopback port,
creates temporary data, and checks discovery, streaming, provider errors,
cancellation, persistence, and agent shutdown without personal API keys.
Provider-import credential checks store a synthetic key in a unique Fritz
Keychain namespace, then verify that a fresh CLI process can authenticate to
the local mock after a keyless overwrite. Local runs need an unlocked Keychain.
`tests/bundled_runtime.py` runs the three protocol suites with one copied Rust
executable and relative harness aliases, including nested child lookup; standalone
Cargo harness executables cannot mask alias dispatch failures.
`tests/coding_integration.py` exercises native tool streams for all six adapters,
real edits and commands, limits, and cancellation of child process groups.
Set `FRITZ_TEST_BIN_DIR` to the staged app’s `Contents/Resources` to repeat the
folder-action workflow against the bundled binaries.
For native project-tool checks, `python3 tests/coding_provider.py` provides
`coding-test` (edits `hello.txt` from `before` to `after` and verifies it) and
`cancel-command` (runs a cancellable sleep). Use a temporary project folder.
`tests/decision_integration.py` exercises the separate decision harness against
local mocks of Jev and OpenAI Decisions using dummy keys, including wire translation, refusals, answer validation
and pipe cancellation. No TypeSafe credential is needed. The same suite checks Ollaya provider separation
and missing-model behavior without downloading weights. After explicitly installing
Laya or Kev into an isolated `FRITZ_MODELS_DIR`, run:

```sh
python3 tests/local_decision_inference.py --data-dir "$fritz_test_data" --models-dir "$fritz_test_data/Models" --model laya-en --bin-dir dist/Fritz.app/Contents/Resources
```

This opt-in check evaluates a fixed English reminder-intent set, all three answer
types, structured score legends, context rejection, and cancellation while native
model loading/inference is active. It never downloads models or uses remote keys.
It flushes an in-flight and terminal JSON receipt for every attempt to stdout,
including the raw event, usage, elapsed time, and owned-child cleanup. Redirect
stdout and stderr into a new run directory so failures retain earlier outcomes.
The outer event wait is 125 seconds so the unchanged 120-second child deadline
can emit its terminal error first. A failure stops the cohort; reruns are separate
recorded attempts, never replacements for failed measurements.

`make build` uses `scripts/build-app.sh` to stage and locally sign a
`dist/FritzWebViewDebug.app` bundle in the primary repository checkout on any branch,
or on `main` in a linked worktree, without a PR lookup. Other linked branches use
`dist/FritzWebViewDebug{PR number}.app` when GitHub CLI can resolve a PR. Linked branches
without a resolvable PR and all detached checkouts use
`dist/FritzWebViewDebug{checkout hash}.app`.
The checkout-path hash continues to isolate the bundle ID, data directory,
Keychain service, and UserDefaults domain. Model weights are shared by all Debug
apps and the regular app at `~/Models/`; chat GGUFs and decision artifacts use
that same flat directory. The first download creates it; listing models does not.
`FRITZ_MODELS_DIR` is an explicit override for isolated model tests. Use
`CONFIGURATION=release make build` for `dist/Fritz.app`, including
`Contents/Resources/fritz`, `Contents/Resources/fritz-harness`,
`Contents/Resources/fritz-decision-harness`, Sparkle, and package resources.
The three entry points share one signed Rust executable: the harness names are
relative symlinks to `fritz`, which dispatches by its invocation name. Each run
still starts a separate process. Cargo retains standalone harness targets for
development and integration checks. Release staging strips local symbols from
the Rust executable and native app before signing, without modifying cached
build products.
Inspect that artifact for packaging failures; a raw Swift executable omits
required resources. `make dev-open` builds and opens the app for normal use.
Neither command installs to `/Applications`.

`make release-build` is the optimized local build at the current Cargo version
and source build number. It does not select a new release version or invoke
distribution tasks. Local Rust and Swift compilation overlap; failure or
cancellation terminates the scheduler's owned process groups before staging.
Full logs are in `dist/build-logs/rust.log` and `swift.log`. Local Xcode builds
use only the host architecture; distribution builds retain existing settings.

Both local configurations reuse a verified unchanged app. Fingerprints hash
tracked and non-ignored source bytes and modes, Cargo/Swift configuration,
build settings, relevant environment, compiler/SDK versions and signing identity.
Publication checks inputs again and records state only after deep signature
verification. Hits also compare all bundled file hashes and reverify signatures;
changed or corrupted bundles fail with an actionable error. Delete
`dist/.build-reuse-release.json` or `dist/.build-reuse-debug.json` to force a rebuild.
Distribution always stages anew and invalidates local Release reuse state.

For startup failures, trace `AgentClient.swift`, its bundled executable, and
the private newline-delimited JSON protocol in [protocol.md](../protocol.md).
The agent's `health` method is a pipe request, not an HTTP endpoint. Cancellation
must reach the Rust request; closing stdin must allow the agent to exit. Check
restart and stale callbacks when changing process supervision.

For signing failures, inspect the staged app with `codesign -dvvv` and verify
with `codesign --verify --deep --strict dist/Fritz.app`. Fix the build script
rather than silently hand-patching the bundle. Local signing does not establish
distribution signing or notarization.

## CI

CI runs for PRs authored by `gabriel`, pushes to `main`, and manual dispatches.
PRs by other authors skip every job, including the final check; rerunning one as
`gabriel` does not change eligibility. Feature-branch pushes do not start a
duplicate run. New commits cancel older runs for the same PR or branch.

macOS checks use the organization's `Mac mini` group, restricted to `rel`,
`rel-tools`, and `fritz`. Its five runners, `runner-mac-mini-1` through
`runner-mac-mini-5`, carry `self-hosted`, `macOS`, `ARM64`, `runner-ci`, and
`runner-snapshot-ci`. Each has its own installation and `_work` directory under
`/Users/runner-ci/actions-runner-mac-mini-N`, owned by the Standard `runner-ci`
macOS account. The previous `local` account's services are disabled; their files
are retained for rollback and must not be started alongside the migrated runners.
Fritz macOS CI additionally requires the `fritz-isolated-account` label, assigned
only to runners installed and run under `runner-ci`. Do not assign this label to
a desktop-account runner. The wrapper checks the actual account name before
reading or changing any Keychain preferences and refuses every other account.
One job first runs `make -j2 ci-prepare` outside the login-session lock.
This compiles Rust test executables and runtime binaries, runs Rust formatting
and Clippy checks, and builds both Swift test packages, with Rust and Swift
preparation concurrent. It uses the normal build-cache locks without touching
Keychain preferences or running UI tests.
The job then runs
`python3 scripts/with-test-keychain.py make -j2 test SWIFT_TEST_FLAGS=--skip-build`
with `FRITZ_SNAPSHOT_MODE=compare` and `SNAPSHOT_ARTIFACTS` pointing to
`dist/snapshot-failures`. Rust/runtime and Swift test groups run concurrently;
visual comparisons execute in the root Swift suite instead of a separate
SwiftPM invocation. Ordinary `make test` still builds as needed and skips
visual comparisons. Use `--skip-build` only after preparation for that checkout.
Cargo still checks freshness during execution. The pinned WhatsApp protocol
crate uses a [build-freshness backport](cargo-build-freshness.md) so its generated
descriptor does not invalidate the artifacts just prepared. Other source or
build-input changes still trigger Cargo's normal compilation.
Keychain tests and snapshot comparisons run under `lockf -k` with the persistent
`~/Library/Caches/runner-mac-mini-session.lock`, also used by REL's Swift tests,
snapshot comparisons, and Staging publication. The lock serializes jobs within
each account; it does not isolate Keychain settings from that account's desktop
applications. Never delete
that lock file while jobs run. Execution takes the session lock before entering
the build-cache wrapper, preserving the lock order used by older workflows;
preparation releases its build-cache locks before waiting for the session.
When the prepared artifacts remain fresh, compilation and Clippy no longer
occupy the login-session lock. This reduces contention with REL and other Fritz runs,
but does not eliminate runner scheduling or cache-lock waits.
The job's 300-minute timeout includes waiting
for other jobs in the dedicated CI account as well as its own checks. The wrapper gives the
job a temporary Keychain for synthetic credentials and attempts to restore its
original default and search list on success, failure, SIGINT, or SIGTERM. Forced
termination or a machine failure can bypass cleanup; using a dedicated account
keeps both in-progress changes and interrupted cleanup away from personal
credentials and desktop applications. It does not unlock the login Keychain.
The service plists live in `runner-ci`'s `~/Library/LaunchAgents` and start at
that account's graphical login. Sign in to `runner-ci` once, then fast-switch
back to the desktop account without logging `runner-ci` out. Running `su` alone
creates a background user session, which does not provide the graphical session
needed for macOS UI tests. Never enable automatic login or disable FileVault for
this setup. Each reboot requires signing in to `runner-ci` again.
Verify the runner processes run as `runner-ci`, are online in GitHub, and leave
the desktop account's default Keychain unchanged before enabling the workflow.
Without a matching online runner, jobs stay queued; do not remove the account
guard to make them run.
Tests compile the Rust and Swift code they
exercise. After tests, CI also builds both Debug app editions and checks their
framework contents. CI does not build, stage, or sign a release app. Verify packaging and signing separately
with `CONFIGURATION=release make build` when needed.
The final “Libraries, app, and runtime” check
runs on `blacksmith-2vcpu-ubuntu-2404` and requires the macOS job to succeed.
The repository must be enabled in the Blacksmith GitHub App for that job to run.

CI sets `FRITZ_BUILD_ROOT` to
`~/Builds/Machine/Fritz/ci/runners/<runner-name-hash>/<toolchain-fingerprint>`.
Each runner retains its own Cargo outputs (including native CMake builds),
SwiftPM scratch directories, Xcode DerivedData, and output locks between jobs.
The runner name is hashed to a stable path component; the toolchain fingerprint
includes Apple, Rust, and CMake versions. A different runner or toolchain selects
separate writable outputs. SwiftPM and Xcode state remain checkout-specific
within that root because their databases contain absolute source paths.

`FRITZ_CACHE_ROOT` remains
`~/Builds/Machine/Fritz/ci/shared/<toolchain-fingerprint>` for shared Swift/Xcode
package downloads and compiler caches. CI also keeps `CARGO_HOME` at
`~/Builds/Machine/Fritz/ci/cargo-home` for shared Cargo registry/Git downloads,
independent of `~/.cargo`. Package managers and compiler-cache tools coordinate
concurrent cache access; those caches do not require Fritz's output lock.
The sccache daemon identity and short startup lock use the shared cache root.

`scripts/build-cache.py` holds only the selected build root's exclusive lock
through compilation, tests, and staging. Different runners can prepare and
build concurrently without waiting on a global compiled-output lock, while
commands using the same outputs remain serialized. The login-session lock
continues to protect Keychain and UI test execution across the dedicated
account. Download/cache-tool locks and that session lock can still cause waits.
Checkout-local `dist/` staging and source cleanup retain their existing behavior;
there is no remote cache transfer.

Existing shared compiled outputs are left untouched for older runs; new runs
warm each runner's output root. Shared package/compiler caches keep their
existing paths and contents. Nothing is copied or deleted during migration.
Retire old output/toolchain directories only when no job is using them, and
preserve lock files while commands may be waiting on them.

## Build storage

Make targets enter `scripts/build-cache.py`, which defaults to `~/Builds/Machine/Fritz`.
`FRITZ_BUILD_ROOT` overrides the writable output root, including direct script
calls and release tools. `FRITZ_CACHE_ROOT` separately selects package/compiler
cache storage and defaults to `FRITZ_BUILD_ROOT`, preserving the local layout.

Under `FRITZ_BUILD_ROOT`:

- `cargo/`: Rust debug/release outputs and incremental dependencies. Local
  worktrees share these by default; CI assigns each runner a separate root.
- `worktrees/<path-hash>/swift`, `swift-app`, and `DerivedData`: SwiftPM and Xcode
  build state for one physical checkout path. These databases contain absolute
  source paths and are not shared as writable state across worktrees.
- `.lock`: an advisory output lock held across builds, tests, and staging.
  Commands sharing a build root wait; separate roots proceed independently.
  `make -j2 test` can run Rust and Swift groups concurrently inside the lock.
- `worktrees/<path-hash>/.lock`: a checkout lock taken before the output lock.
  Setup holds only this lock so another checkout can build while it resolves
  dependencies. Setup and builds in the same checkout serialize access to its
  SwiftPM scratch directories and Xcode DerivedData.

Under `FRITZ_CACHE_ROOT`:

- `downloads/waproto/<sha256>.desc`: the checksum-verified, revision-pinned
  Protobuf descriptor. Setup, Rust preparation/checks/tests, and app builds fetch
  it before Cargo runs; `make prepare-rust-inputs` prepares it explicitly. A
  per-asset lock and atomic publication support concurrent runner downloads.
  Verified cache hits work offline without changing timestamps. Cargo itself
  reads the prepared input and reports missing/corrupt inputs with recovery steps.
- `swift-packages/` and `xcode-packages/`: shared package download caches.
  Cargo's downloads remain under `CARGO_HOME`. Package managers coordinate their
  own caches, so fetching dependencies can still wait on their locks.
- `compiler-cache/rust/` and `compiler-cache/xcode/`: sccache and Xcode compiler
  caches. sccache uses a private per-user socket directory under `/tmp`, with
  sockets keyed by cache-root hash to respect macOS's Unix socket path limit.
  Startup is serialized with a short cache-root lock and deferred until needed.
  Local workspace incremental compilation remains enabled; dependencies can
  reuse compiler results across source checkouts and runner output roots.

Cargo decides which artifacts remain fresh using its normal fingerprints;
sharing storage does not guarantee every compilation is reusable. Swift/Xcode
reuse downloaded packages across worktrees, while compiled app products remain
per checkout. Finished app bundles and update archives stay in `dist/`; runtime
data and credentials are unaffected. Opening the project directly in Xcode uses
Xcode's own locations; use `make build` for this layout and complete app staging.

Existing `target`, `.build`, `app/.build`, and `dist/DerivedData` directories are
not migrated or deleted. After old builds stop, they can be removed manually.
To reclaim the new storage, stop all Fritz build commands and remove the desired
cache directories; preserve the root and checkout `.lock` files so waiting
processes never lock different files. Removing a worktree does not automatically
remove its build storage.

For direct commands, enter the wrapper rather than accessing shared Cargo output
without the lock:

```sh
python3 scripts/build-cache.py cargo build --locked
python3 scripts/build-cache.py python3 tests/integration.py
```

The wrapper exports the resolved `FRITZ_BUILD_ROOT` and `FRITZ_CACHE_ROOT`,
`CARGO_TARGET_DIR`, `FRITZ_TEST_BIN_DIR`,
`FRITZ_SWIFT_BUILD`, `FRITZ_APP_SWIFT_BUILD`, `FRITZ_SWIFT_CACHE`,
`FRITZ_DERIVED_DATA`, and `FRITZ_XCODE_CACHE`. Make configures the Swift and Xcode
commands with these paths. Plain `cargo`/`swift` commands outside the wrapper
use their normal output defaults, but Cargo commands that compile waproto need
the prepared descriptor and wrapper-selected `FRITZ_CACHE_ROOT`. Run
`make prepare-rust-inputs` and use the wrapper for direct Cargo invocations. To get the resolved DerivedData path
without building, use `python3 scripts/build-cache.py --derived-data`.
The setup script uses `--setup` to configure these same paths with only the
checkout lock; reserve that mode for dependency resolution without compilation
or consumption of shared build outputs.

## Isolated UI and CLI verification

Use synthetic data and the mock provider for manual checks as well. For example,
after building, start the mock server in a terminal:

```sh
python3 tests/mock_provider.py
```

It prints the selected port. In another terminal, set `fritz_test_port` to that
port and create an isolated registry:

```sh
fritz_test_data="$(mktemp -d "${TMPDIR:-/tmp}/fritz-ui.XXXXXX")"
FRITZ_DATA_DIR="$fritz_test_data" dist/Fritz.app/Contents/Resources/fritz \
  add-provider --name Test --provider openai-compatible \
  --base-url "http://127.0.0.1:$fritz_test_port/v1" --model fritz-test --default
open -n --env "FRITZ_DATA_DIR=$fritz_test_data" "$PWD/dist/Fritz.app"
```

LaunchServices needs the explicit `open --env` value; setting the shell variable
alone is not sufficient. `-n` starts the test instance rather than reusing an
already running app. Verify the test provider is present before interacting.
Keep that app running while checking the affected workflow, then quit only that
instance and stop the mock server with Ctrl-C in its terminal.

`FRITZ_DATA_DIR` isolates provider metadata, projects, threads, and drafts for
the Release app. It does **not** isolate its Keychain service
`dev.fritz.provider-credentials`, macOS/Sparkle-managed window and update-engine preferences. Use newly created, keyless mock connections for Release app tests.
Debug apps use a worktree-specific bundle ID, data directory, Keychain
service, and UserDefaults domain. The bundled CLI needs `FRITZ_DATA_DIR`,
`FRITZ_MODELS_DIR`, and `FRITZ_KEYCHAIN_SERVICE` set explicitly to use that Debug
identity and model storage outside the app. For isolated Debug app verification,
launch with `open -n --env "FRITZ_MODELS_DIR=$fritz_test_data/Models"` and use the
same explicit override for its bundled CLI; this avoids reading shared weights.

Local-model unit tests use small deterministic HTTP fixtures for checksums,
interruption, cancellation, and atomic installation. CLI integration tests verify
the catalog and missing-model behavior without downloading weights. For an
explicit real-download smoke check, use an isolated `FRITZ_DATA_DIR`, install a
small catalog entry with `fritz local-models install MODEL_ID`, then add a `fritz`
provider and exercise streaming and cancellation. Use only the isolated test
directory's model files and provider registry. The native Metal runtime is bundled into fritz-harness.

After that explicit installation, run the opt-in native lifecycle check:

```sh
python3 tests/local_inference.py --data-dir "$fritz_test_data"
```

This uses an existing Fritz provider in the selected test directory; it never
downloads weights or contacts a remote provider. It checks streamed text,
cancellation, continued agent health, and clean Metal teardown when stdin closes
during generation. It is deliberately separate from `make test`.

When debugging, verify a PID's executable path belongs to the staged bundle
before attaching or terminating it. Do not use `killall`/`pkill` by app name.
Keep staged bundles and test data in this checkout. Use the build wrapper when
consuming shared Cargo outputs; do not bypass its lock or share SwiftPM scratch
directories or Xcode DerivedData between worktrees.

## Shared libraries

The root `Package.swift` publishes `Fritz`, `FritzState` and `FritzUpdates`; the app package
and Xcode target consume them. Run `make test-swift` for public-library and application tests using the
configured build storage. The model catalog lives
in `Sources/Fritz/LocalModels.json` and is consumed by both Swift and Rust.
The staged Xcode app must include the Fritz resource bundle as well as Sparkle
and Textual resources. See [the library guide](../libraries.md).

## Browser import and password filling

The Browser menu imports local Chrome, Chromium, Brave, and Edge profile data.
Discovery reads directory metadata only. Source SQLite connections use read-only
transactions, including committed WAL data. Keychain reads occur only after an
explicit Import action. The reader supports Chromium's macOS `v10` format and
cookie database versions through 24, checks the encrypted cookie's domain hash,
and rejects unsupported encryption. Reference contracts are Chromium's
[key provider](https://github.com/chromium/chromium/blob/156.0.8078.88/components/os_crypt/async/browser/keychain_key_provider.mm),
[encryptor](https://github.com/chromium/chromium/blob/156.0.8078.88/components/os_crypt/async/common/encryptor.cc),
and [cookie database](https://github.com/chromium/chromium/blob/156.0.8078.88/net/extras/sqlite/sqlite_persistent_cookie_store.cc).
Partitioned cookies are skipped because the public destination APIs cannot
preserve their partition keys. They must never be imported as unpartitioned.

Website passwords use the staged bundle's `FritzBrowserPasswordsService`,
separate from provider credentials and Chromium's cookie encryption item.
Debug and ad-hoc builds generate a new service when staging. Signed Release
builds use a stable edition-specific service. No password data is written to
application databases. Manual filling rechecks the main document's exact
origin and the form's destination, never submits, and never targets frames.

`BrowserImportTests` uses synthetic Keychain items, fixed independently generated
ciphertexts, and temporary SQLite databases with active WAL connections. It
covers domain-integrity failures, unsupported encryption, skipped records,
account replacement, origin isolation, and actual WebKit form filling. Run it
through `make test-swift`. For UI verification, open Import in each staged
edition, inspect source selection, disabled options, status, cancellation, and
Quit. Do not import a personal profile or inspect its credentials as an automated
check. If import writes are interrupted, the reported completed records remain;
a retry merges and replaces matching records.

## Bundled llama.cpp runtime

Chat and Bosun statically link llama.cpp at
`7c2653acc749258dc62067da62d07024d971ccd2` through `native/bridge.cpp`.
CMake enables CPU and Metal with embedded shaders and Jinja chat support;
servers, tools, examples, subprocess support, OpenSSL, BLAS and OpenMP are disabled.
The CMake build tree is keyed by checkout path and compiler environment inside
Cargo output storage, because CMake caches absolute source paths.
The app needs no additional runtime dylibs or inference service. `make setup`
initializes the submodule; CI checks it out recursively. Update the gitlink,
Bosun catalog engine revision and runtime qualification together when upgrading.

Each model handle serializes access to its context. Rust task cancellation sets
an atomic flag observed during model loading, prompt batches and token decoding;
workers retain ownership until native calls exit. Chat uses llama.cpp's model
Jinja template, tool grammar and response parser. Only complete, validated tool
calls enter Fritz's existing action executor. Bosun retains its compiler,
slot mapping, probability normalization and typed answers, reading only the final
position's eligible logits without sampling an answer token.

See the [migration verification and package measurements](llama-runtime-migration-2026-11-10.md)
for the exercised native workflows and final artifact provenance.
