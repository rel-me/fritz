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
.product(name: "Fritz", package: "fritz")
.product(name: "FritzUpdates", package: "fritz") // optional; adds Sparkle
```

Requires Swift 6.3 and macOS 15. The `Fritz` product has no Sparkle or Textual
target dependency. Its model catalog is a package resource; hosts must bundle
SwiftPM resources using their normal Xcode/SwiftPM build integration.

| Module | Public infrastructure |
| --- | --- |
| `Fritz` | Provider connections and registry wire models, endpoint presets/categories, discovered models, model capabilities and picker grouping, pinned local-model descriptors and hardware information, appearance, CLI symlink installation, private-pipe agent client |
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

Appearance and update channel `saved` conveniences read the host process's
standard UserDefaults. The host owns applying appearance, saving preferences,
starting update checks and calling `setUpdateChannel`. REL's existing `regular`
channel value must be migrated to Fritz's `release` value during adoption.
Sparkle feed/signing configuration remains in the host app's Info.plist.

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
| `config::RegistryStore` | Supply a data directory; updates are atomic and locked. No credentials are serialized. |
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
