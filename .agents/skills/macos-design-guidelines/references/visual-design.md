# Visual design and forms

Use Fritz's existing typography, spacing, native materials, and semantic colors.
Check hierarchy, alignment, text overflow, and contrast in light/dark appearance.
Do not impose a universal spacing grid or prohibit every explicit font size.
Preserve system control behavior and selected appearance unless a concrete
product requirement calls for customization.

Keep grouped form/list cells for actual controls, actions, and records. Field
labels and values stay with their controls; helper text and validation/status
belong in headers, footers, help, or feedback outside cells. Omit empty sections
and placeholders unless the user needs an action to continue. Do not add a
ContentUnavailableView to every empty collection.

Verify shared visual changes across consumers using the root UI verification procedure.
Preserve Fritz's native chat surface and window architecture instead of
replacing them to imitate a generic SwiftUI sample. Use [accessibility](accessibility.md) for legibility/settings checks.
