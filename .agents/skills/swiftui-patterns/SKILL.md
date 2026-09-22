---
name: swiftui-patterns
description: Implement macOS SwiftUI scenes, settings, toolbars, commands, and sidebar/inspector layouts in Fritz. Use for desktop UI implementation, not general code review or a full HIG audit.
license: MIT
metadata:
  author: OpenAI
  source: build-macos-apps 0.1.4
---

# macOS SwiftUI implementation

Read the nearest existing scene or component and its state owner before editing.
Use Fritz's existing structure and declared platform/toolchain settings. Determine
whether state belongs to the app, scene, window, or control, then use the narrowest
existing ownership mechanism. Keep selection explicit and stable.

Load only the reference needed for the affected surface:

- [Windowing](references/windowing.md): scene choice and window opening.
- [Commands and menus](references/commands-menus.md): shortcuts, focused actions,
  and command routing.
- [Settings](references/settings.md): dedicated settings scenes and preferences.
- [Split views and inspectors](references/split-inspectors.md): sidebar selection,
  native materials, and detail/inspector composition.
- [Menu bar extras](references/menu-bar-extra.md): when actually changing that
  surface, including its relationship to the regular app window.

Prefer native desktop affordances and semantic colors/materials. Keep native
sidebar rows lightweight and preserve system selection. Follow AGENTS.md for
form rows, helper text, and empty states. Keep primary actions discoverable via
menus, toolbars, and appropriate keyboard shortcuts.

Use SwiftUI scene and command APIs where they express the behavior correctly.
When AppKit is required, follow nearby interop code and keep the bridge narrow;
do not invent an alternate app launch or agent transport. Split unrelated
responsibilities when needed for the requested change, without reorganizing the
project or scaffolding a new app.

Follow root AGENTS.md for `make dev-open` and affected UI checks.
A successful build alone does not verify a visual change. These local references
are self-contained and require no globally installed macOS skills.
