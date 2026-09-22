# Fritz

A native macOS chat app extracted from REL’s chat and model interfaces. The main window uses REL’s unified toolbar and inset chat surface, with projects and their threads in the left sidebar. **Model Providers** opens from the toolbar’s CPU button or ⌘,. The composer, searchable model and provider pickers, provider category filters, status badges, model previews, and native button styling are adapted from REL.

This first version is the chat foundation for a coding agent. It can discuss and generate code; filesystem tools, command execution, and autonomous editing are not implemented yet.

## Build and run

Requires macOS 15+, Xcode / Swift 6.3, Rust 1.88+ with rustfmt and Clippy, CMake (for the native inference runtime), and Python 3 for integration tests.

```sh
make setup     # check tools and resolve committed dependency versions
make dev-open
```

This builds `dist/Fritz.app`, bundles the Rust `fritz` executable and Markdown resources, signs the app locally, and opens it. Use `CONFIGURATION=release make build` for an optimized local build. Neither command installs or replaces an app in `/Applications`.

The native Xcode project is `app/Fritz.xcodeproj`; its source specification is `app/project.yml`. Regenerate project structure with `xcodegen generate --spec app/project.yml`. Use the Makefile to stage the complete app with its Rust agent. `app/Package.swift` supports fast Swift builds and unit tests.

Use **+ → New Project** to choose an existing folder and create its first thread. The folder is a project reference; Fritz does not read or modify its files. Use **New Thread** or ⌘N for another conversation. Threads retain separate transcripts, drafts, and model settings. Their titles come from the first message; project and thread context menus also offer Rename.

In **Model Providers**, click **Add**, choose a provider using search or the Local / Remote / Frontier / Hosted / Custom filters, and enter its API key. Models load automatically; the refresh button retries discovery. **Advanced** contains connection naming and default/manual model choices. Supported adapters: OpenAI (Responses), OpenRouter, Anthropic, Google Gemini, Ollama, and OpenAI-compatible services. Fireworks, Amazon Bedrock Mantle, and Baseten have endpoint presets. The generic endpoint expects the OpenAI chat completions protocol. Ollama uses its native API. Catalogs are discovered live; a manual model ID also supports services without a catalog endpoint.

The composer includes model search, provider filtering, recent selections, and reasoning/speed options for recognized OpenAI models. Return sends; Shift-Return inserts a newline. Escape stops generation. ⌘N creates a thread, ⇧⌘N opens New Project, and ⌘, opens Model Providers. Chat Options can clear the current thread after confirmation. Projects and the selected thread are restored on the next launch. Switching threads keeps an in-progress response attached to its original thread.

## Download local models

In **Model Providers → Add**, choose **Fritz** (also shown under **Local**),
select a model, and click **Download & Add**. The setup shows the download size,
recommended memory, license, progress, and installation status. Cancel stops the
download; Retry starts a fresh attempt. After verification, the provider is saved
and installed models become available in the chat model picker. Edit the Fritz
provider to download another model. Removing a provider leaves downloaded weights
available for reuse.

The catalog and installer are adapted from REL, with Fritz's own storage and
private agent transport. Downloads are pinned to repository revisions, file sizes,
and SHA-256 hashes. Models run offline inside the Rust agent using llama.cpp and
Metal, without Ollama or a local HTTP service. No API key is needed. Listing
models or sending a chat never starts a download. Weights live under
`~/Library/Application Support/Fritz/Data/Models/` (or `FRITZ_DATA_DIR/Models`).
The native runtime's licenses ship in the app; each model's license is linked in
setup. Memory recommendations are estimates. Local chat supports an 8,192-token
context and up to 2,048 output tokens per reply.

## CLI

```sh
make install-cli  # symlink the bundled CLI into ~/.local/bin
fritz --help
fritz local-models list
fritz local-models install qwen3-0.6b-q4_k_m
fritz add-provider --name Fritz --provider fritz --model qwen3-0.6b-q4_k_m
fritz chat "Explain Rust ownership" --connection Fritz
fritz providers
fritz add-provider --name Ollama --provider ollama --model llama3.2 --default
fritz models
fritz chat "Explain Rust ownership" --model llama3.2
fritz chat --connection Ollama --model llama3.2 < prompt.txt
```

Use `--api-key-stdin` with `add-provider` to read a key from standard input. Keys are never command-line arguments. `fritz default-provider NAME` changes the default, and `fritz remove-provider NAME` removes the connection and its saved key. The CLI shares the app’s provider settings; CLI chat is a single request and does not modify the app’s transcript.

## Architecture and storage

- `app/`: SwiftUI/AppKit executable with Textual for native Markdown and code rendering.
- `src/`: Rust provider adapters, catalog discovery, streaming, credential storage, registry, and CLI. The app supervises `fritz --agent` over private stdin/stdout pipes using request IDs and newline-delimited JSON. Stop cancels the corresponding asynchronous network request. Closing the app terminates its agent; closing the window keeps the app available in the Dock.
- `~/Library/Application Support/Fritz/Data/providers.json`: versioned, non-secret provider metadata. Writes are atomic and locked across processes.
- `~/Library/Application Support/Fritz/Data/workspace.json`: project folders, thread names and identities, and the selected thread.
- `~/Library/Application Support/Fritz/Data/Threads/`: independent thread transcripts and preferences. Partial interrupted responses are retained for display and omitted from future model context. An existing `chat.json` is imported once into a **Chats** project and kept as a recovery copy.
- API keys live in macOS Keychain under `dev.fritz.provider-credentials`. Fritz does not read REL’s configuration or credentials. Changing an endpoint requires entering a key again.
- `FRITZ_DATA_DIR` overrides data storage for isolated development and tests. Model recents use Fritz’s UserDefaults domain.

The app has no embedded web engine or browser runtime. Only the selected chat/provider components are included; the Rust runtime is independent of REL and its tools.

## Verification

```sh
make test
make check
```

Tests cover stream framing, adapter payloads, model selection, provider categories, independent thread persistence, previous-chat recovery, persistence failures, local-model integrity and cancellation, and the real CLI/agent against deterministic local fixtures. They do not download real model weights, require API keys, or contact paid services. Real provider credentials are required to validate account-specific model availability and usage limits.

See [docs/protocol.md](docs/protocol.md) for the private app/agent protocol.

## Development guidance

The Codex environment in [.codex/environments/environment.toml](.codex/environments/environment.toml)
provides worktree setup and Run Fritz, Build, Test, and Check actions.
[AGENTS.md](AGENTS.md) documents the architecture and development rules.
The repository includes five [native development skills](docs/agents/skills.md)
adapted from REL for SwiftUI implementation/review, macOS design, concurrency,
and builds/AppKit. See [runtime verification](docs/agents/runtime-verification.md)
and [UI verification](docs/agents/ui-verification.md) for local testing.
