# Runtime verification

`make setup` prepares dependencies using the committed Cargo and Swift package
locks. It needs full Xcode with Swift 6.3+, Rust 1.95+ with rustfmt and Clippy,
CMake for a native TLS dependency, and Python 3. It does not install toolchains, change Git
branches, copy local credentials, build an app, or launch one. XcodeGen is needed only when regenerating
`app/Fritz.xcodeproj` from `app/project.yml`.

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
`tests/coding_integration.py` exercises native tool streams for all six adapters,
real edits and commands, limits, and cancellation of child process groups.
Set `FRITZ_TEST_BIN_DIR` to the staged app’s `Contents/Resources` to repeat the
folder-action workflow against the bundled binaries.
For native project-tool checks, `python3 tests/coding_provider.py` provides
`coding-test` (edits `hello.txt` from `before` to `after` and verifies it) and
`cancel-command` (runs a cancellable sleep). Use a temporary project folder.
`tests/decision_integration.py` exercises the separate decision harness against
a local mock of Jev's typed API using a dummy key, including answer validation
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
`dist/FritzDebug.app` bundle in the primary repository checkout on any branch,
or on `main` in a linked worktree, without a PR lookup. Other linked branches use
`dist/FritzDebug{PR number}.app` when GitHub CLI can resolve a PR. Linked branches
without a resolvable PR and all detached checkouts use
`dist/FritzDebug{checkout hash}.app`.
The checkout-path hash continues to isolate the bundle ID, data directory,
Keychain service, and UserDefaults domain. Model weights are shared by all Debug
apps and the regular app at `~/Models/`; chat GGUFs and decision artifacts use
that same flat directory. The first download creates it; listing models does not.
`FRITZ_MODELS_DIR` is an explicit override for isolated model tests. Use
`CONFIGURATION=release make build` for `dist/Fritz.app`, including
`Contents/Resources/fritz`, `Contents/Resources/fritz-harness`,
`Contents/Resources/fritz-decision-harness`, Sparkle, and package resources.
All three binaries are signed and verified.
Inspect that artifact for packaging failures; a raw Swift executable omits
required resources. `make dev-open` builds and opens the app for normal use.
Neither command installs to `/Applications`.

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
One job runs
`python3 scripts/with-test-keychain.py make -j2 test` (Rust/runtime and Swift
test groups concurrently), snapshot comparisons, then `make check`.
Keychain tests and snapshot comparisons run under `lockf -k` with the persistent
`~/Library/Caches/runner-mac-mini-session.lock`, also used by REL's Swift tests,
snapshot comparisons, and Staging publication. The lock serializes jobs within
each account; it does not isolate Keychain settings from that account's desktop
applications. Never delete
that lock file while jobs run. The job's 300-minute timeout includes waiting
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
exercise; CI does not build, stage, or sign a release app. Verify packaging and signing separately
with `CONFIGURATION=release make build` when needed.
The final “Libraries, app, and runtime” check
runs on `blacksmith-2vcpu-ubuntu-2404` and requires the macOS job to succeed.
The repository must be enabled in the Blacksmith GitHub App for that job to run.

The Mini uses `~/Builds/Fritz/ci/<runner-name>/<toolchain-fingerprint>` across CI runs. The
fingerprint includes Apple, Rust, and CMake toolchain versions, so a toolchain
change selects fresh storage. Runner-specific roots keep concurrent jobs' mutable
build outputs separate. Source cleanup does not touch these directories.
There is no remote cache transfer. Old toolchain directories can be removed when
no build is using them.

## Build storage

Make targets enter `scripts/build-cache.py`, which defaults to `~/Builds/Fritz`.
`FRITZ_BUILD_ROOT` overrides the root (including for direct script calls and
release tools). The layout is:

- `cargo/`: shared Rust debug/release outputs and incremental dependencies.
- `swift-packages/` and `xcode-packages/`: shared package download caches.
- `worktrees/<path-hash>/swift`, `swift-app`, and `DerivedData`: SwiftPM and Xcode
  build state for one physical checkout path. These databases contain absolute
  source paths and are not reused as writable build state by other worktrees.
- `.lock`: an advisory lock held across the entire command, including tests and
  staging, for builds and tests. A competing build or test waits; `make -j2 test`
  can still run its Rust and Swift groups concurrently inside the lock.
- `worktrees/<path-hash>/.lock`: a checkout lock taken before the shared lock.
  Setup holds only this lock, so it can resolve dependencies while another
  worktree builds or tests. Setup and builds in the same checkout serialize
  access to SwiftPM scratch directories and Xcode DerivedData. Cargo, SwiftPM,
  and Xcode coordinate their own package download caches, so dependency fetches
  may still wait on those tools' locks.

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

The wrapper exports `CARGO_TARGET_DIR`, `FRITZ_TEST_BIN_DIR`,
`FRITZ_SWIFT_BUILD`, `FRITZ_APP_SWIFT_BUILD`, `FRITZ_SWIFT_CACHE`,
`FRITZ_DERIVED_DATA`, and `FRITZ_XCODE_CACHE`. Make configures the Swift and Xcode
commands with these paths. Plain `cargo`/`swift` commands outside the wrapper
continue using their normal defaults. To get the resolved DerivedData path
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
