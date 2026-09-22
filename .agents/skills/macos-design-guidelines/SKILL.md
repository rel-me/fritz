---
name: macos-design-guidelines
description: Audit a macOS interface against Human Interface Guidelines, keyboard access, and accessibility. Use for requested design reviews or a specific platform-convention question, not every SwiftUI edit.
license: MIT
metadata:
  author: platform-design-skills
  version: "1.0.0"
---

# macOS design review

Evaluate the requested Fritz surface and user workflow. Preserve repository UI
rules and platform targets. Report concrete usability or accessibility problems,
not every optional platform feature the app could implement.

Read only the relevant topic references:

- [Menus](references/menus.md) and [toolbars](references/toolbars.md): command
  discoverability, labels, shortcuts, and customization.
- [Windows](references/windows.md), [sidebars](references/sidebars.md), and
  [popovers](references/popovers.md): sizing, selection, presentation, and chrome.
- [Keyboard](references/keyboard.md) and [pointer](references/pointer.md): focus,
  activation, contextual actions, and input behavior.
- [Accessibility](references/accessibility.md): VoiceOver, contrast, text, and
  reduced motion/transparency.
- [Visual design](references/visual-design.md): native materials, semantic colors,
  typography, and appearance.
- [Notifications](references/notifications.md) and
  [system integration](references/system-integration.md): only when those
  capabilities are part of the requested work.

The [keyboard reference](references/keyboard-reference.md) is a lookup table.
For a comprehensive audit, choose the topic references matching the app's actual
surfaces. Optional platform features are not shipping requirements. Follow the
repository's native form and quiet empty-state rules.

For each finding, explain the affected user action, evidence, and recommended
change. Prioritize barriers to completing tasks, keyboard access, and assistive
technology over aesthetic preferences. If implementing a fix, follow the root
AGENTS.md runtime and UI verification requirements.
