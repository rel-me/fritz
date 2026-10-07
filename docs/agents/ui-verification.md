# Native UI verification

Use `make build` for incremental Debug builds of the complete staged app during
UI development and verification. Use the mock-provider setup in
[runtime verification](runtime-verification.md). Inspect the actual native
surface affected by the change; process launch and compilation do not verify
layout, focus, command routing, or state restoration.

Trace shared style/layout components to their consuming views. Check the
relevant light/dark, empty, populated, loading, and error states. For changes to
the following surfaces, include these behaviors:

- **Window and toolbar:** traffic lights, drag regions, resize/minimum width,
  persistent sidebar without a toggle, + menu, New Project folder selection/cancel, and Settings
  opening with Command-comma. The toolbar opens the Models page in Settings.
  Enter and exit fullscreen in light and dark appearance; the toolbar background
  should match the workspace surround in both modes. Preserve the sidebar's rounded
  outline through the titlebar around the traffic lights; it must not stop below
  a flat toolbar strip.
  Compare the toolbar with the exposed padding around the rounded detail corner:
  the color must remain continuous in fullscreen as well as in a normal window.
- **Projects and threads:** blank sidebar and detail surfaces when no project or
  thread exists, with creation available from the toolbar and menu. Check stable
  selection, rename, New Thread/Command-N, independent transcripts and drafts,
  model settings, and launch restoration. Main chat has no tab strip. Check that
  the native right inspector opens without tabs, resizes using its divider, closes
  from its button, and can be hidden and reopened without changing the selected conversation. Check the panel toggle
  at minimum window width. New Chat stays at the trailing edge of the main chat
  toolbar when the inspector opens and resizes; there is no bottom panel or
  chat-tab keyboard commands.
- **Composer and chat:** model search/filter/recent choices, Return to send,
  Shift-Return for a newline, Escape to stop, Markdown rendering, scrolling,
  error feedback, and switching threads while a response streams. A new thread
  shows only the composer, without an empty conversation message.
- **Settings:** exactly one app-menu Settings item and Command-comma reopening the
  selected page; shared title-free unified toolbar, native traffic lights, a
  persistent sidebar without a toggle, and a rounded detail surface that begins
  below the toolbar in light/dark appearance. General appearance,
  update channel, CLI install feedback, Models selection, blank and populated model
  lists, local-model download and New Models/Edit Models process controls (First use
  by default, App start persistence, weight load/unload, installed path and Finder
  reveal, PID, address, multi-model memory warnings including API first-use
  admission, errors, and quit cleanup), automatic Local API startup with no models,
  Service status, and
  Debug page navigation.
- **Providers:** combined LLM and decision provider list, add/edit/cancel, field
  labels, discovery and refresh, default/manual model choices, validation, and
  connection errors.

Check keyboard focus and command targets when moving between chat, popovers,
and Providers. Exercise accessibility or reduced-motion/transparency settings
when the changed behavior depends on them. Capture before/after screenshots
when they help review a visual change, using synthetic text and no credentials.
With an app-owned sheet open (including New Models), verify that Command-Q,
the app-menu Quit item, and a system Quit request terminate the staged app
without first dismissing the sheet. Repeat while the sheet has keyboard focus
or cancellable work is in progress when those states are affected.

## Shared UI snapshots

`tests/FritzUISnapshotTests` compares the public FritzUI controls using
[swiftui-snapshot-testing](https://github.com/gabriel/swiftui-snapshot-testing).
The dependency is test-only. The test harness settles native controls in an
offscreen AppKit window with
explicit appearance, sRGB color space, and 2× backing pixels, then passes that
rendered surface through its `assertSnapshot(view:device:)` API. This captures the native appearance before the package’s light-only host
compares the pixels; it does not replace controls with stand-ins. Fixtures set a
fixed size, English locale, light/dark color scheme, blue tint, and hidden scroll
indicators, with synthetic model/provider values and no network or credentials.
Model-download fixtures pass a fixed 32 GB Apple silicon hardware profile so
memory warnings and hardware summaries do not depend on the runner's Mac.
The harness also pins each AppKit scroll view to overlay scrollers: hiding
indicators alone leaves a reserved gutter on Macs using legacy scrollbars.
Native table column widths are rounded up to whole points before capture to avoid
a half-point autosizing variation in header dividers across AppKit initialization contexts.

Run `make check-ui-snapshots` before committing shared UI changes. CI runs the
same command and uploads mismatches from `dist/snapshot-failures`. Ordinary
`make test` skips the visual suite so CLI/unit tests work without a GUI session.
A missing reference fails comparison without creating a new baseline. The
comparison command rejects recording mode.

For a deliberate new or changed reference, first run comparisons and inspect the
failure, then record only the affected tests:

```sh
FRITZ_SNAPSHOT_MODE=record swift test --filter SharedControlSnapshots/testModelPickerPopulated
make check-ui-snapshots
```

Use `FRITZ_SNAPSHOT_RECORD_PREFIX=models-download-` when recording that family
in the full suite's AppKit initialization context. Unmatched snapshots still
compare; comparison mode ignores this recording selector.

Recording intentionally reports test failures while writing references. Review
every new/changed PNG in `tests/FritzUISnapshotTests/__Snapshots__` before the
comparison run. Never use recording in CI or relax precision to accept a change.
The initial references were recorded with macOS 26.6.2 (25G83), Xcode 26.6
(17F113), and Swift 6.3 on Apple Silicon. Native rendering depends on the OS;
compare on that baseline environment and review intentional OS upgrades.

Coverage includes model search, empty/no-results, recents/selection, badges,
Bedrock and generic adapter separation, wrapping provider filters, provider
categories/search, and enabled/disabled content, primary, inline, link, panel,
and toolbar buttons in
both color schemes. Floating Liquid Glass styles produce incomplete transparent
readbacks with this renderer on macOS 26; verify those styles in the staged app
instead of committing blank baselines. App-specific loading/error, streaming,
keyboard routing, and persistence
still require the native workflow checks above. Snapshot comparisons complement
`make test`; they do not replace those interaction checks.

If a task introduces snapshot tests, compare the affected suites before updating
references. Inspect actual, expected, and diff images. Record only intentional
changes, review them, then rerun with recording disabled. Do not loosen tolerances
or blindly regenerate baselines to make failures pass. Report the observed
workflow, test results, and any rendering/environment limitations.
