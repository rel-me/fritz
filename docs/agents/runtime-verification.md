# Runtime verification

`make setup` prepares dependencies using the committed Cargo and Swift package
locks. It needs full Xcode with Swift 6.3+, Rust 1.88+ with rustfmt and Clippy,
CMake for llama.cpp, and Python 3. It does not install toolchains, change Git
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
cancellation, persistence, and agent shutdown without API keys.
`tests/coding_integration.py` exercises native tool streams for all six adapters,
real edits and commands, limits, and cancellation of child process groups.
Set `FRITZ_TEST_BIN_DIR` to the staged app’s `Contents/Resources` to repeat the
coding workflow against the bundled binaries.
For native project-tool checks, `python3 tests/coding_provider.py` provides
`coding-test` (edits `hello.txt` from `before` to `after` and verifies it) and
`cancel-command` (runs a cancellable sleep). Use a temporary project folder.

`make build` uses `scripts/build-app.sh` to stage and locally sign a
`dist/FrizDebug{PR}.app` bundle in a branch with an open PR. Use
`CONFIGURATION=release make build` for `dist/Fritz.app`, including
`Contents/Resources/fritz`, `Contents/Resources/fritz-harness`, Sparkle, and package resources. Both binaries are signed and verified.
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

CI runs once per pull-request update, on pushes to `main`, and on manual dispatch.
Feature-branch pushes do not also start a duplicate run. New commits cancel older
runs for the same PR or branch.

Four hosted macOS jobs run independently: `make test-runtime`, `make test-swift`,
`make check`, and `CONFIGURATION=release make build`. `make test` still runs both
test groups locally. The final “Libraries, app, and runtime” check requires all
four jobs to succeed and preserves the original check name for branch protection.

Rust dependency build outputs are cached separately for tests, Clippy, and
release builds, keyed by the Rust and Apple toolchains and dependency inputs.
Swift test build directories are cached by Apple toolchain and package locks,
with a new snapshot per commit. Xcode packages and DerivedData are cached by
Apple toolchain, project configuration, and package locks, also with a new snapshot
per commit. Every run invokes the incremental release build, staging, and signing.
Caches contain build data only, never runtime data or credentials, and are
disposable. A cold run still compiles all dependencies; warm-run savings depend
on which toolchains and locks changed.

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
`dev.fritz.provider-credentials`, model recents in UserDefaults, or window
preferences. Use newly created, keyless mock connections for Release app tests.
PR Debug apps use a worktree-specific bundle ID, data directory, Keychain
service, and UserDefaults domain. The bundled CLI needs `FRITZ_DATA_DIR` and
`FRITZ_KEYCHAIN_SERVICE` set explicitly to use that Debug identity outside the app.

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
Keep build outputs and test data in this checkout; never share writable target,
DerivedData, app bundle, or SwiftPM build directories between worktrees.

## Shared libraries

The root `Package.swift` publishes `Fritz` and `FritzUpdates`; the app package
and Xcode target consume them. Run `swift test` for public-library tests and
`swift test --package-path app` for application tests. The model catalog lives
in `Sources/Fritz/LocalModels.json` and is consumed by both Swift and Rust.
The staged Xcode app must include the Fritz resource bundle as well as Sparkle
and Textual resources. See [the library guide](../libraries.md).
