# Windowing

Read Fritz's existing scene and window coordinator before changing presentation.
Keep window-scoped selection and drafts separate from app-wide services. Use the
existing window-opening route and stable identifiers; verify first launch,
reopening, focus transfer, and closing the last window for the affected workflow.

Choose WindowGroup for independent instances, Window for a singleton surface,
and Settings for preferences when those APIs fit the current architecture.
Do not migrate an existing AppKit-managed window just to match a sample. A scene
name alone does not establish launch or restoration behavior.

Use the local build-macos-apps AppKit references for low-level titlebar, responder,
or window lifecycle changes. Follow root runtime and UI verification.
