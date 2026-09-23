# Fritz libraries

Fritz provides source-distributed Swift libraries and a Rust library for native
macOS hosts. The app consumes these same modules. APIs are initial 0.x APIs;
pin a Git revision until a library release has been tagged. There is no separate
XCFramework download or crates.io release yet.

## Swift Package Manager

Add this repository's root package, then select the products your target uses:

```swift
.package(url: "https://github.com/rel-me/fritz", revision: "<commit-sha>")

// Target dependencies:
.product(name: "FritzState", package: "fritz") // optional; SQLite only
.product(name: "Fritz", package: "fritz")
.product(name: "FritzUpdates", package: "fritz") // optional; adds Sparkle
```

Requires Swift 6.3 and macOS 15. The `Fritz` product has no Sparkle or Textual
target dependency. Its model catalog is a package resource; hosts must bundle
SwiftPM resources using their normal Xcode/SwiftPM build integration.

| Module | Public infrastructure |
| --- | --- |
| `Fritz` | Provider connections and registry wire models, endpoint presets/categories, discovered models, model capabilities and picker grouping, pinned local-model descriptors and hardware information, appearance, CLI symlink installation, private-pipe agent client |
| `FritzState` | Host-owned SQLite connections, bound values, transactions, ordered migrations and schema validation; no app models, Sparkle or inference dependency |
| `FritzUpdates` | Sparkle configuration validation, updater lifecycle and required-update state, release/beta/dev channels, Check for Updates command |
| `FritzApp` | Executable module: scenes, project/thread persistence, observable app stores, settings and chat UI, app-specific process configuration |

The visible application and bundle remain **Fritz** and `Fritz.app`. The Xcode
scheme remains `Fritz`. `app/Package.swift` supplies the `FritzApp` executable for
Swift tests; use `make build` for a complete signed application.

```swift
import Fritz

let installer = CommandLineInstaller(
    cliURL: URL(fileURLWithPath: "/Applications/Example.app/Contents/Resources/example")
)
let result = installer.install()
```

The installer derives the link name from the executable's last path component,
uses writable directories already in PATH, and never overwrites an unrelated
file. The host supplies its install path and presents its own feedback.

`AgentClient` is main-actor isolated. Initialize it with the bundled executable
URL, arguments and environment, then call `start()`. It speaks Fritz's private
NDJSON protocol; it is not an adapter for REL's current HTTP/browser transport.
Use `request`, or `stream` with an explicit request ID and `cancel` when a stream
consumer stops. The owner must call `stop()` on shutdown. No process launches at
module import. Never pass credentials through arguments or environment; use the
private protocol. See [protocol.md](protocol.md).

Hosts own loading appearance and update-channel preferences, applying appearance,
starting update checks and calling `setUpdateChannel`. There are no implicit
UserDefaults reads. Sparkle feed/signing configuration remains in the host app's
Info.plist.

## SQLite state

`FritzState.StateDatabase` takes an explicit file URL, ordered SQL migration
strings and a dictionary of required tables/columns. Migration index + 1 is
SQLite's `user_version`. Append migrations; never edit one already shipped.
Opening acquires an immediate transaction before reading the version, applies
all pending migrations, validates tables, required columns, foreign keys and
integrity, then commits. Failure rolls back DDL and the version together.
Newer or unversioned nonempty databases are rejected without reset.

```swift
import FritzState

let database = try StateDatabase(
    url: dataDirectory.appendingPathComponent("state.sqlite"),
    migrations: ["CREATE TABLE notes (id TEXT PRIMARY KEY, body TEXT NOT NULL);"],
    schema: ["notes": ["id", "body"]]
)
try database.transaction {
    try database.execute("INSERT INTO notes VALUES (?, ?)", [.text("first"), .text("Hello")])
}
let notes = try database.query("SELECT body FROM notes ORDER BY id")
```

A recursive lock serializes the Swift connection and holds it across each
synchronous transaction closure. Do not nest transactions or dispatch work to
another thread and wait from inside a transaction. Hosts can call the library
from a worker queue; Fritz's small synchronous app stores use their UI owner.
Rows expose typed `SQLValue`s; bind record contents rather than interpolating SQL.
Migrations and schema definitions are trusted host code, not user input.

The independent Rust crate `fritz-state` has no inference or app dependency and
can be consumed directly (`fritz-state = { git = "https://github.com/rel-me/fritz",
rev = "<commit-sha>" }`). It is also re-exported as `fritz::state`.
Its `Database` exposes the same ownership pattern, with
`open(path, migrations, schema)`, `connection()` and a transactional closure.
It re-exports its `rusqlite` version for host schema/query code. Rust owns
`providers.sqlite`; the app owns `workspace.sqlite`, so schemas can evolve
independently without two runtimes racing to migrate the same file. Credentials
remain in Keychain. The app-specific schema and Codable records stay in FritzApp.

Both implementations adapt REL's `src/agent/database.rs` and
`src/agent/migrations.rs`: WAL, NORMAL synchronization, 5-second busy timeout,
bounded journals, private database/sidecar permissions, immediate schema
transactions, version rejection and structural validation. REL's browser tables,
old-version migrations, recovery/import machinery and dependencies are not copied.
WAL initialization retries only SQLite BUSY errors for up to five seconds; failed
statements release their locks before retrying. Migrations and user transactions
are never automatically replayed.
Fritz starts at schema 1; legacy JSON and UserDefaults are deliberately ignored.
Use a SQLite-aware backup (or close all connections before copying), since live
WAL files can contain committed data not yet present in the main database file.

## Rust

```toml
[dependencies]
fritz = { git = "https://github.com/rel-me/fritz", rev = "<commit-sha>" }
```

The library is named `fritz`; the `fritz` and `fritz-harness` binaries remain
separate targets. This initial library requires macOS and the native inference
build toolchain (Rust 1.88+, CMake and Xcode). Native Metal inference is currently
part of the crate, rather than an optional feature. `publish = false` prevents
an accidental crates.io upload; Git and path dependencies are supported.

| API | Host responsibility |
| --- | --- |
| `state::Database` | Supply a database path, ordered migrations and expected schema; own connection scheduling. |
| `config::RegistryStore` | Supply a data directory; updates are atomic SQLite transactions. No credentials are serialized. |
| `config::CredentialStore` | Supply a Keychain service name owned by the host. No Keychain migration happens automatically. |
| `provider::discover_with_key` | Supply a connection and credential explicitly. Remote discovery does not consult Fritz's registry or Keychain. |
| `local::models::ModelStore` | Supply the host data directory. Inventory verifies existing weights; only `download` downloads. |
| `local::models::{catalog, manifest}` | Read the shared, revision/size/SHA-256-pinned model catalog. |
| `local::inference::Engine` | Use `installed_in` with the host's ModelStore; own streaming, cancellation and `unload()` before process teardown. |
| `harness::run` | Supply the connection, chat request and credential in memory. This is Fritz's coding/chat policy, not REL's browser-tool harness. |
| `harness_client::chat_with_input` | Supply a bundled harness executable and explicit input; transport is private pipes. Dropping the future closes stdin for cancellation. |
| `tools::Workspace` | Supply a trusted project directory; commands run with user permissions, not an OS sandbox. |

```rust
use fritz::config::RegistryStore;
use fritz::local::models::ModelStore;

async fn inventory() -> anyhow::Result<()> {
    let providers = RegistryStore::new("/path/to/host/data");
    let registry = providers.load()?;
    let models = ModelStore::new("/path/to/host/data");
    let inventory = models.inventory().await?;
    Ok(())
}
```

Module-level convenience functions retain Fritz's data paths and Keychain
namespace. `provider::discover_with_key` with the built-in `Fritz` provider,
`local::{chat, generate}`, the Ollama-compatible local API, and local-model calls
through the Fritz harness also retain the default Fritz model cache. Hosts
requiring independent storage should use `ModelStore` and `Engine::installed_in`
directly, not mutate process-wide environment variables to switch stores.

The inference backend is process-global, while engine weights and generation
state are owned by the engine. Dropping a generation future signals its worker
to cancel; `unload()` waits for the worker before releasing weights. Neither
inventory nor engine construction downloads a model.

## REL adoption map

This extraction was compared with REL's AppUpdater, CommandLineInstaller,
appearance/channel models, provider metadata and ai-service local-model code.
It prepares common infrastructure without changing REL in this repository:

- Adopt `Fritz` for provider/model metadata and CLI installation, retaining REL's
  endpoint and wire-model adapters where they differ.
- Adopt `FritzUpdates` for the shared Sparkle lifecycle after migrating the
  stored channel value and preserving REL's feed and signing key.
- Adopt Rust model storage and inference with REL-owned data and Keychain paths.
- Keep REL's browser engine, browser tools, HTTP agent transport and application
  persistence in REL. Keep Fritz's project/thread stores and views in FritzApp.

REL must reconcile protocol and model-catalog differences during its later
migration; this change does not assert drop-in compatibility for either entire
application. There is no CEF or browser dependency in Fritz.

## License and verification

Project-authored app and library code is AGPL-3.0-only. See [LICENSE](../LICENSE)
and [CONTRIBUTING.md](../CONTRIBUTING.md). A proprietary combined application
needs appropriate separate rights; this repository grants no commercial exception.
Third-party dependencies, bundled notices and vendored skills retain their own
licenses. Model weights have their separately linked licenses.

`make test` runs Rust tests, public Swift-library tests, app tests, and CLI/agent
integration tests. The public API tests deliberately avoid `@testable` imports
for library APIs, and Rust integration tests exercise the crate from outside its
module boundary. `make check` runs formatting and Clippy. `make build` verifies
the staged app, framework/resource packaging, Rust binaries and signatures.
