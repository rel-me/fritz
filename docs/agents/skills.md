# Repository-owned skills

Fritz keeps its development skills under `.agents/skills/`, tracked with the code.
They require no global skill installation or plugin. Codex discovers this folder
from the repository and its subdirectories. Keep entry points short and load
only references needed for a task; preserve project safeguards in AGENTS.md.

- `swift-concurrency`: diagnose isolation, Sendable, task lifetime, and async code.
- `build-macos-apps`: build/debug Fritz, triage tests and signing, and bridge AppKit.
- `swiftui-patterns`: implement desktop UI.
- `swiftui-pro`: review correctness, state/task ownership, lifecycle, and performance.
- `macos-design-guidelines`: audit HIG/accessibility or answer a specific native
  convention question.

Do not install duplicate global copies. Codex does not merge same-name skills;
remove a personal duplicate or disable its absolute SKILL.md path with a
`[[skills.config]]` entry (`enabled = false`) in the user's Codex configuration.
Keep machine-specific paths/configuration outside this repository. Restart
Codex after changing user configuration. See the
[official skill documentation](https://learn.chatgpt.com/docs/build-skills).

## Adaptation provenance

These skills were adapted from the installed sources below. Their source
metadata declares MIT licensing. Entry points have distinct triggers and
use Fritz's platform/build contract. The macOS guide was split into topic
references; SwiftUI implementation references no longer require a global AppKit
skill. Generic new-app scaffolding and repeated checklists were removed from the
implementation entry point because Fritz is an existing app.

Source SKILL.md SHA-256 values identify the upstream inputs:

- `macos-design-guidelines`: platform-design-skills 1.0.0.
  `9fa44a38eee0138d6aaf41b7f34223bcd9b25099e4706846b8773124fc5b6ecc`
- `swiftui-pro`: Paul Hudson, SwiftUI-Agent-Skill 1.1.
  `8b58a171afc1dcf9c42d85414af2dc506c8c92bf2c77527adb4d52b884f4d715`
- `swiftui-patterns`: OpenAI build-macos-apps 0.1.4.
  `ebfc06b1c1e11cadec83e5c204b20f33f01db1c36cb5796639567bd8eac0fe07`

## Additional skill sources

- `swift-concurrency`: [Antoine van der Lee's Swift Concurrency Agent Skill](https://github.com/AvdLee/Swift-Concurrency-Agent-Skill/tree/45fa49e4e0b2af4d43b1cb458903f8030ac993bd/skills/swift-concurrency),
  pinned to `45fa49e4e0b2af4d43b1cb458903f8030ac993bd` (MIT, license included).
  Input SKILL.md SHA-256:
  `8c667b2ff988251c7c291abe046b77d7b8fcfbe3b5ed36961e25e224b1ead491`.
  References are vendored with whitespace normalization and interface assets
  are included; the entry point is shortened
  and adapted to Fritz's toolchain, private-pipe agent ownership, and verification procedures.
- `build-macos-apps`: OpenAI build-macos-apps 0.1.4 (MIT metadata), cache revision
  `11c74d6b`. Consolidates build-run-debug, test-triage, signing-entitlements,
  telemetry, and appkit-interop guidance; includes the four AppKit references.
  Uses Fritz's existing build/staging workflow instead of upstream scaffolding
  and process-wide restart instructions. SwiftUI topics remain in the existing
  `swiftui-patterns` skill. Input SKILL.md SHA-256 values:
  - build-run-debug: `bd32f3fa611fd731d01113450929aaeab8b40bfdda669b6cad76d877a096b722`
  - test-triage: `e6ed34d34d2b4f62a262f3ab9076ab02bfb75d7661491383493bee78545b7851`
  - signing-entitlements: `79326e5096325b53c4350db9e1586c9a2ef56976705f01c24d3643a592dc3030`
  - telemetry: `64fae6fd88c411d108b321462f90b74deb42fb043b815baae04b199a07dfbd25`
  - appkit-interop: `7c91be82e30340ed9c929270f102965da3d67bcf509eecf8bf207c8a679fd3b6`

Both additions are repository-owned and require no global plugin or skill.
Upstream concurrency examples are topic references, not instructions to change
Fritz's platform, toolchain, dependencies, or test harness.

## Fritz refinements

The SwiftUI review references now focus on evidence-backed correctness and
request lifetime. Design/accessibility conventions live in the macOS design
skill. Mobile defaults, blanket modernization rules,
and duplicate audit checklists were removed. The implementation references
preserve Fritz's existing scenes and stores instead of scaffolding a generic app.

## Fritz adaptation

Added to Fritz on 2026-09-22. The upstream attribution, source hashes,
concurrency license, and interface assets above are retained.

Entry points and project-specific references now describe Fritz's actual
SwiftUI/AppKit scenes, stores, private-pipe agent, Make targets, and tests.
UI verification is manual with the mock provider; Fritz does not yet have a
visual snapshot suite. Generic upstream concurrency examples remain reference
material, not instructions to expand the app's scope or change its toolchain.
