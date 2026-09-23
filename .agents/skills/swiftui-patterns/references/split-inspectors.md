# Split views and inspectors

Preserve the affected workspace's layout owner and stable selection. Fritz uses a
project/thread sidebar and chat detail; do not replace one with NavigationSplitView
solely because it is the generic SwiftUI option.

Keep rows lightweight, using native selection and materials where applicable.
Put richer content in the detail or inspector surface. Avoid replacing the root
view identity when selection changes if focus or local edits need to survive.

Check column minimum sizes, long titles, resizing, collapse, and focus return.
Use an inspector when it complements the main task; do not move an unrelated
editor into a modal or inspector as part of a narrow change. For AppKit split
coordination, follow the existing bridge and local build-macos-apps references.
