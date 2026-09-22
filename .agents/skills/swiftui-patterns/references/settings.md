# Settings

Extend Fritz's existing settings surface and preference owner. Use AppStorage only
for values whose persistence contract belongs in UserDefaults; keep session data
and credentials in their existing services. Do not add a parallel settings scene
or store merely to simplify the UI.

Group related controls and preserve field labels, validation, save/cancel
behavior, and keyboard access. Keep supporting text outside grouped cells and
omit empty sections as required by AGENTS.md. Use the local macOS design
reference for form layout rather than introducing a second rule set here.

When a change needs panels or first-responder integration, use the local
build-macos-apps references and the nearest existing Fritz bridge.
