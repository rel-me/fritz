# Fritz

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="design/branding/FritzLogoDark.svg">
  <img src="design/branding/FritzLogo.svg" alt="Fritz" width="360">
</picture>

A native macOS personal assistant with persistent conversations and a choice of local or remote models. Fritz keeps chat at the center of the window. The current release provides chat and model management; [the personal assistant plan](docs/personal-assistant-plan.md) sets out how Fritz will add personal context, useful actions, and opt-in follow-through.

## Install

Open the release DMG and drag Fritz onto the Applications shortcut. Eject the
disk image, then open Fritz from Applications.

## Get started

1. Open **Settings → Models**, click **+**, and choose a provider. Add an API key
   if required; Fritz stores credentials in macOS Keychain.
2. For an on-device model, choose **New Local Model** from the **+** or **File**
   menu, download a model, and add a **Fritz** provider for it.
3. Create a conversation with **New Chat** or ⌘N, choose a model in the composer,
   and send a message. Conversations retain their own transcripts, drafts, and
   model settings across launches.

Chat supports OpenAI, Anthropic, Google Gemini, OpenRouter, Ollama, and
OpenAI-compatible services. Native local models run through mistral.rs with
Metal acceleration, without an Ollama installation or API key. Each conversation
uses Rig's agent runtime inside a separate bundled `fritz-harness` process.
Decision models provide separately invoked typed judgments and are not chat models.

Fritz currently groups conversations under projects in the sidebar. Attaching a
folder lets models with native tool support read and change files and run local
processes. **These actions run with your macOS user permissions; the folder is
not an OS sandbox.** Attach only folders you trust. This workflow is planned to
move toward narrower, permission-based personal sources. See [folder access and limits](docs/folder-actions.md).

## CLI

Install the bundled CLI from **Settings → General → Command Line**, then use
an existing provider connection:

```sh
fritz providers
fritz models
fritz chat "Help me plan a quiet weekend" --connection Fritz
```

For a checkout-local CLI, run `make install-cli`. See the [CLI guide](docs/cli.md)
for provider setup, local models, stdin input, and folder actions.

## Build and run

Requires macOS 15+, Xcode / Swift 6.3, Rust 1.95+ with rustfmt and Clippy,
CMake, Python 3.11+, and mise.

```sh
make setup     # check tools and resolve committed dependencies
make dev-open  # build and launch this checkout's Debug app
```

`CONFIGURATION=release make build` stages an optimized app at `dist/Fritz.app`.
Builds bundle the Rust runtime and Markdown resources and are locally signed by
default. See [building Fritz](docs/agents/building.md) for toolchain setup,
Debug app naming, build caches, and Xcode project details.

Run the local checks with:

```sh
make test
make check
```

See [runtime verification](docs/agents/runtime-verification.md),
[UI verification](docs/agents/ui-verification.md), and
[AGENTS.md](AGENTS.md) for development guidance.

## Documentation

- [Using chat](docs/chat.md): projects, conversations, keyboard shortcuts, activity, and usage.
- [Providers](docs/providers.md): connections, discovery, model selection, and import/export.
- [Local models](docs/local-models.md): downloads, storage, hardware estimates, and the local API.
- [Decision models](docs/decision-models.md): remote and experimental local judgment backends.
- [App updates](docs/updates.md): update channels and release behavior.
- [Architecture and storage](docs/architecture.md): harnesses, process ownership, and persistence.
- [Shared libraries](docs/libraries.md): Swift and Rust APIs for native hosts.
- [Private protocol](docs/protocol.md) and [decision harness](docs/decision-harness.md): integration contracts.
- [Releases](docs/agents/releases.md), [model evaluation](docs/agents/model-evaluation.md), and [development skills](docs/agents/skills.md).

## License

Fritz's app and shared libraries are licensed under **AGPL-3.0-only**. See
[LICENSE](LICENSE) and [CONTRIBUTING.md](CONTRIBUTING.md). Commercial use is
allowed under the license's source-sharing requirements. Third-party dependencies,
vendored material and model weights retain their respective licenses.
