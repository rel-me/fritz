# Native UI verification

Build the complete staged app and use the mock-provider setup in
[runtime verification](runtime-verification.md). Inspect the actual native
surface affected by the change; process launch and compilation do not verify
layout, focus, command routing, or state restoration.

Trace shared style/layout components to their consuming views. Check the
relevant light/dark, empty, populated, loading, and error states. For changes to
the following surfaces, include these behaviors:

- **Window and toolbar:** traffic lights, drag regions, resize/minimum width,
  sidebar visibility, + menu, New Project folder selection/cancel, and Settings
  opening with Command-comma. The toolbar opens the Model Providers page in Settings.
  Enter and exit fullscreen in light and dark appearance; the toolbar background
  should match the workspace surround in both modes, including with the sidebar hidden.
  With the sidebar shown, preserve its rounded outline through the titlebar around
  the traffic lights and sidebar toggle; it must not stop below a flat toolbar strip.
  Compare the toolbar with the exposed padding around the rounded detail corner:
  the color must remain continuous in fullscreen as well as in a normal window.
- **Projects and threads:** stable selection, rename, New Thread/Command-N,
  independent transcripts and drafts, model settings, and launch restoration.
- **Composer and chat:** model search/filter/recent choices, Return to send,
  Shift-Return for a newline, Escape to stop, Markdown/code rendering, scrolling,
  error feedback, and switching threads while a response streams.
- **Settings:** exactly one app-menu Settings item and Command-comma reopening the
  selected page; shared title-free unified toolbar, native traffic lights, and
  rounded inset detail surface in light/dark appearance. General appearance,
  update channel, CLI install feedback, Model Providers selection, Local Models
  process controls, Service status, and Debug page navigation.
- **Providers:** category filters, add/edit/cancel, field labels, discovery and
  refresh, default/manual model choices, validation, and connection errors.

Check keyboard focus and command targets when moving between chat, popovers,
and Providers. Exercise accessibility or reduced-motion/transparency settings
when the changed behavior depends on them. Capture before/after screenshots
when they help review a visual change, using synthetic text and no credentials.

Fritz currently has model/workspace unit tests and CLI integration tests, but
no automated visual snapshot suite. Do not claim a snapshot comparison ran.
Manual checks complement `make test`.

If a task introduces snapshot tests, compare the affected suites before updating
references. Inspect actual, expected, and diff images. Record only intentional
changes, review them, then rerun with recording disabled. Do not loosen tolerances
or blindly regenerate baselines to make failures pass. Report the observed
workflow, test results, and any rendering/environment limitations.
