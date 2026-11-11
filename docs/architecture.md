# Architecture and storage

[Back to README](../README.md)

Every conversation runs through Rig 0.43's agent runtime inside the bundled
`fritz-harness` process. Fritz supplies the provider adapters, local inference, and
application policy. Folder actions use Fritz's own tools registered with Rig; Rig does
not supply the file and shell implementations. Their paths are relative to the attached
folder, with `.` identifying its root.

- `Sources/Fritz/`, `Sources/FritzUI/`, `Sources/FritzState/`, `Sources/FritzUpdates/`: reusable Swift libraries and the shared model catalog.
- `app/`: `FritzApp` SwiftUI/AppKit executable with Textual for native Markdown rendering.
- `crates/fritz-state/`: independent Rust SQLite state library, also re-exported by `fritz::state`.
- `src/`: Rust provider adapters, catalog discovery, credential storage, registry, and CLI. The app supervises `fritz --agent` over private stdin/stdout pipes using request IDs and newline-delimited JSON.
- `src/bin/fritz-harness.rs`, `src/harness.rs`, `src/harness/`: the separate per-request harness, Rig-driven agent runtime, and provider-native action history. The service resolves credentials and passes them to the harness through private stdin. The harness opens no listener and reads no Keychain items.
- `src/bin/fritz-decision-harness.rs`, `src/decision.rs`, `src/decision_client.rs`: a separate typed-judgment runtime with OpenAI Decisions, Jev, and native Ollaya adapters. The host supplies remote credentials over a private pipe; local decisions need no key, and decision connections are separate from conversational providers.
- `src/tools.rs`: current folder actions, including listing, reading, creating, and changing files, plus noninteractive local processes. Stop cancels the harness request and terminates child process groups. Closing the app closes the private pipes; closing only the window keeps the app available in the Dock.
- `~/Library/Application Support/Fritz/Data/providers.sqlite`: non-secret provider records and the default connection, owned by Rust. Concurrent CLI/agent updates use SQLite transactions.
- `~/Library/Application Support/Fritz/Data/workspace.sqlite`: projects, threads, ordered messages and tool activity, drafts, model choices, selection, appearance, update channel, settings page and model recents, owned by the native app.
- SQLite connections use WAL, foreign keys, bounded lock waits, private file permissions, schema validation and atomic versioned migrations. A corrupt or newer database produces an error; it is never silently reset.
- Legacy JSON files and old application preferences are ignored. There is no import or backwards compatibility. Existing files are left on disk but are no longer read or written.
- Provider secrets remain in Fritz’s Keychain namespace; they are never stored in SQLite. Chat and decision model files share the [model storage locations](local-models.md#storage-and-runtime).
- `FRITZ_DATA_DIR` overrides databases and the default regular-app/CLI model root (`FRITZ_DATA_DIR/Models`). Debug apps use the shared system model root. Set `FRITZ_MODELS_DIR` to override model storage independently, including isolated Debug app tests. Neither override changes the Keychain namespace or macOS/Sparkle-managed preferences.
- Interrupted prose is omitted from future context unless it has tool records; the next turn then receives the activity and an interruption notice so it can inspect current state before retrying.

The native app owns the manual Browser window and tab state. The default build
hosts system WebKit. The opt-in Chromium build packages upstream CEF and its
sandboxed helpers behind the same browser controls. Chromium's cookie encryption
uses an explicit Fritz-owned Keychain service and account. Each Debug or
ad-hoc build receives a unique browser profile and namespace. Certificate-signed
Release builds retain a stable namespace. The browser is separate
from the Rust runtime, which handles providers, local models, chat, and folder
actions.

## Shared libraries

The repository root is a Swift package exposing **Fritz** (provider/model metadata,
private-pipe transport, appearance and CLI installation), **FritzUI** (shared
model/provider pickers and native button styles), **Bonsplit** (reusable tab strips and
split panes with REL’s customization), and **FritzUpdates** (Sparkle lifecycle and
update policy). The **fritz** Rust library exposes provider networking, host-scoped
registry/Keychain/model storage, native inference and the current folder actions. The
app's executable module is **FritzApp**; the product remains **Fritz.app**. The shared
chat composer supports host-registered `@` references to plugins, artifacts, and
entities. See [the library guide](libraries.md) for Git dependency examples, public
APIs, ownership and the planned REL adoption.
