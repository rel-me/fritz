# Accessibility of the affected workflow

Inspect the effective accessibility name, role, value, state, and actions of each
changed control. Icon-only controls can use an explicit accessibility label or a
system control with a meaningful title. Decorative imagery should not create
noise. Do not infer a missing label solely from the visible glyph.

Check keyboard completion and logical focus traversal, including custom AppKit
controls and error feedback. See [keyboard access](keyboard.md) for focus and
shortcut conventions. Ensure information conveyed by color also has a useful
non-color cue when needed.

Verify legibility, contrast, and text clipping in the supported macOS appearances
and accessibility settings. Prefer semantic text and system controls; assess
custom sizes against the actual desktop layout instead of imposing mobile tap
sizes or mobile font APIs.

Respect reduced motion/transparency and increased contrast. Native materials may
already adapt; inspect their behavior before adding custom opaque replacements.
Report barriers to real actions, not a demand for every accessibility modifier.
