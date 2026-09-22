# Runtime verification

`make setup` prepares dependencies using the committed Cargo and Swift package
locks. It needs full Xcode with Swift 6.3+, Rust 1.88+ with rustfmt and Clippy,
CMake for llama.cpp, and Python 3. It does not install toolchains, change Git
branches, copy local credentials, build an app, or launch one. XcodeGen is needed only when regenerating
`app/Fritz.xcodeproj` from `app/project.yml`.

The [Codex environment](../../.codex/environments/environment.toml) adapts REL's
local-environment layout to Fritz. Setup runs `make setup`; the toolbar actions
invoke the existing Make targets. See the [official local-environment documentation](https://learn.chatgpt.com/docs/environments/local-environment)
for setup and action behavior.

## Checks and staged artifact

For runtime changes:

```sh
make test
make check
make build
```

`make test` runs Rust tests, Swift tests, and the real CLI/agent integration
harness. The harness starts `tests/mock_provider.py` on a free loopback port,
creates temporary data, and checks discovery, streaming, provider errors,
cancellation, persistence, and agent shutdown without API keys.

`make build` uses `scripts/build-app.sh` to stage and locally sign
`dist/Fritz.app`, including `Contents/Resources/fritz` and package resources.
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

`FRITZ_DATA_DIR` isolates provider metadata, projects, threads, and drafts. It
does **not** isolate Keychain service `dev.fritz.provider-credentials`, model
recents in UserDefaults, or macOS window preferences. Use only newly created,
keyless mock connections; do not exercise personal accounts. Fritz currently
has no per-worktree bundle ID or Keychain allocator. Do not claim otherwise or
import REL's runtime allocator.

Local-model unit tests use small deterministic HTTP fixtures for checksums,
interruption, cancellation, and atomic installation. CLI integration tests verify
the catalog and missing-model behavior without downloading weights. For an
explicit real-download smoke check, use an isolated `FRITZ_DATA_DIR`, install a
small catalog entry with `fritz local-models install MODEL_ID`, then add a `fritz`
provider and exercise streaming and cancellation. Do not borrow REL's model files
or provider registry. The native Metal runtime is bundled into the Fritz CLI.

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
