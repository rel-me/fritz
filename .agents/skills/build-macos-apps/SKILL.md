---
name: build-macos-apps
description: Build, run, debug, instrument, and diagnose signing or test failures in Fritz's macOS app, or implement a focused AppKit bridge. Use swiftui-patterns for ordinary SwiftUI implementation.
license: MIT
metadata:
  author: OpenAI
  source: build-macos-apps 0.1.4
---

# Build macOS apps in Fritz

Read the affected Make target and nearby implementation before changing the
build or runtime. Fritz already has an app, bundle staging, and test harnesses.
Use those entry points and declared platform/toolchain settings.

## Build and debug

Read [runtime verification](../../../docs/agents/runtime-verification.md).
`make setup` resolves locked dependencies; `make build` stages and signs
`dist/Fritz.app`, and `make dev-open` builds and opens it for normal use. For
verification, launch that artifact with the documented isolated data directory
and mock provider. Use its bundled `Contents/Resources/fritz` for CLI checks.
The app supervises `fritz --agent` through private pipes.

Classify the first actionable failure as compilation, linking, bundle staging,
signing, startup, or runtime behavior. Read `scripts/build-app.sh` and capture
the smallest useful diagnostic before changing it. A SwiftPM build alone does
not verify the staged app, package resources, or embedded agent.

For a crash, inspect the crash report or attach LLDB only to a PID verified to
belong to this checkout's test bundle. Trace pipe startup, pending requests, and
process teardown for agent failures. Never use broad process-name killing or
attach to an installed app or another checkout's processes.

Keep the checked-in Xcode project synchronized with `app/project.yml` using
XcodeGen when structure changes. Use the existing Make/build path rather than
launching a raw GUI executable or hand-staging a second bundle. Optimized local
builds use `CONFIGURATION=release make build`; installing or distributing an app
requires the corresponding user request.

## Tests, logging, and signing

Run the affected repository checks (`make test` and `make check` for runtime
changes). Distinguish setup/fixture failures, compiler errors, assertions,
crashes, and async timing failures. Narrow reruns around the failing case; a
suspected flake needs evidence. Visual changes also require
[native UI checks](../../../docs/agents/ui-verification.md).

For instrumentation, follow nearby logging conventions and keep output bounded.
Keep credentials, prompts, responses, and personal project data out of logs.
Agent stdout is exclusively the JSON protocol. Filter diagnostics to the
verified test process. Use signposts when measuring a span and exercise the
affected path after staging the build.

For signing failures, inspect the artifact with `codesign -dvvv --entitlements
:-` and its plist with `plutil -p`. Distinguish signature, entitlement,
nested-code, hardened-runtime, and distribution failures. Fix the supported
build path instead of manually re-signing the bundle or inventing entitlements.
Local signing does not establish notarization.

## Native implementation

Use [swiftui-patterns](../swiftui-patterns/SKILL.md) for scenes, settings,
toolbars, commands, and sidebars. When SwiftUI lacks the required behavior,
define the specific AppKit boundary and load only its reference:

- [Representables](references/representables.md): controls, coordinators, and update loops.
- [Windows and panels](references/window-panels.md): NSWindow and file panels.
- [Responder chain](references/responder-menus.md): focus and menu validation.
- [Drag and drop](references/drag-drop-pasteboard.md): pasteboard and file transfer.

Keep observable state ownership in the existing model; coordinators hold
AppKit delegates and lifecycle glue. Verify teardown, repeated SwiftUI updates,
and feedback-loop prevention. Use the local concurrency skill for async
ownership changes; load review or HIG skills only for their respective tasks.

Report what was verified, the artifact/runtime used, and any remaining blocker.
Do not infer a working UI from a successful build or process launch.
