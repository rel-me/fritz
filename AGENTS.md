# Fritz Agent Guidance

Fritz is a native macOS coding-assistant foundation. Keep the initial product focused on Chat and Providers. The chat interface is the main content.

## Product and architecture

- SwiftUI/AppKit lives in `app/Sources/Fritz`; Rust owns provider networking, model discovery, saved credentials, and the `fritz` CLI in `src`.
- The main sidebar contains projects and their threads; Model Providers opens from the window toolbar. Preserve independent transcripts, drafts, model settings, and the selected thread across launches.
- The app supervises its bundled `fritz --agent` through private pipes. Each chat runs in a separate bundled `fritz-harness` process. Do not add an HTTP daemon just for app communication.
- Keep credentials out of registry files, command-line arguments, environment variables, logs, and agent responses. Use Fritz’s Keychain namespace.
- Preserve separation from the source app: no CEF, embedded web engine, browsing sessions, profiles, proxy management, or REL runtime dependencies.
- Keep documentation honest about the current scope: Chat is tool-free; Code uses project file tools and noninteractive commands. Commands run with user permissions, not in an OS sandbox. Preserve cancellation, tool activity records, native tool-result history, and execution limits.

## Build and runtime verification

- `make setup` checks the local toolchain and resolves locked dependencies. Codex uses `.codex/environments/environment.toml` for setup and Run, Build, Test, and Check actions.
- `make build` stages and signs `dist/Fritz.app`; `make dev-open` builds and launches it. Use these entry points so verification includes the Rust agent and bundled Markdown resources. A SwiftPM build alone does not verify the complete app.
- The checked-in Xcode project is generated from `app/project.yml` using XcodeGen. Update both when project structure changes. Preserve the declared platform and language settings and committed dependency locks.
- For runtime, agent, or packaging changes, read [runtime verification](docs/agents/runtime-verification.md). Run `make test` and `make check`, then build the staged app and exercise the affected workflow. Documentation and skill-only changes do not require an app build.
- Use `FRITZ_DATA_DIR` with an isolated directory and `tests/mock_provider.py` for end-to-end verification. Do not use personal provider credentials for automated checks. The override isolates data files, not the Keychain namespace or UserDefaults.
- Operate only on processes verified to belong to this checkout and test run. Never use broad process-name killing, interact with another checkout's app, or test an installed app in `/Applications`. Optimized local builds use `CONFIGURATION=release make build`; installation and distribution require a task that requests them.
- Keep `target`, `app/.build`, `dist/DerivedData`, staged apps, and runtime data local to the checkout. Do not seed them from another worktree or copy REL's local environment files.

## Native UI and documentation

For SwiftUI/AppKit changes, read [UI verification](docs/agents/ui-verification.md).
Trace shared components to their consumers and check affected appearance,
loading, empty, error, and populated states. Report what was actually exercised;
a successful build or launch alone does not prove the UI works.

Reserve list/table/grouped Form rows for controls, actions, and records. Keep
labels with their controls; put headings, helper text, validation, and status in
headers, footers, help, or feedback outside cells. Omit empty sections and
placeholders unless an action is needed to continue. Preserve native selection,
keyboard command routing, and the unified toolbar. Keep useful diagnostic menu
items available in optimized builds rather than hiding them behind `#if DEBUG`.

Maintain user-facing setup and CLI documentation in `README.md`, the private
agent protocol in `docs/protocol.md`, and development procedures in
`docs/agents/`. Update the relevant documentation when behavior changes.

## Skills and completion

Repository-owned skills live in `.agents/skills/`; see [sources and routing](docs/agents/skills.md).
Use `swiftui-patterns` for implementation, `swiftui-pro` for focused reviews,
`macos-design-guidelines` for HIG/accessibility questions, `swift-concurrency`
for task/isolation work, and `build-macos-apps` for build/debug/signing or AppKit
boundaries. Load only the references needed for the task; no global installation
is required.

Review the diff and run the affected local checks before reporting completion.
Use focused conventional commits and `codex/<short-name>` branches when the
task includes committing or preparing a PR; preserve unrelated user changes.
When publishing a PR is part of the task, push to `origin`, use a ready,
non-draft PR unless requested otherwise, and report its number, title, link,
checks, and exact blockers. Prefix the task title with `#<number> ·` once a PR
exists, preserving its descriptive title. After pushing, finish without polling
CI or reviews unless the user explicitly requests monitoring. Never describe
unperformed verification as passing.

## Commits and pull requests

For repository changes, make a focused conventional commit on the current
branch. If detached, create a `codex/<short-name>` branch first. Push to
`origin`; create a ready, non-draft PR if none is open for the branch, and use
the existing PR otherwise.
