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
  persistent sidebar without a toggle, + menu, New Project default folder creation,
  custom folder selection/cancel, and Settings
  opening with Command-comma. The toolbar CPU and network buttons open Local Models and Remote Models directly, without a dropdown.
  Enter and exit fullscreen in light and dark appearance; the toolbar background
  should match the workspace surround in both modes. Preserve the sidebar's rounded
  outline through the titlebar around the traffic lights; it must not stop below
  a flat toolbar strip.
  Compare the toolbar with the exposed padding around the rounded detail corner:
  the color must remain continuous in fullscreen as well as in a normal window.
- **Local model status bar:** Check the bottom of the main window while a local
  model starts, runs, and stops. Verify memory updates, idle and remote-only chats,
  the View menu toggle, and preference restoration after relaunch. Running chats
  should remain visible in the bar when switching threads.
  With fresh settings, verify that the bar is visible and empty while idle.
  Starting and stopping a model should leave the footer and composer in place.
  Check that showing the bar leaves the composer and sidebar above it at the
  minimum window size and with the browser inspector open.
  Start a local model without sending a message. Verify the bar shows it as
  Loaded with its allocated KV cache size. Check that the chat harness reports
  its cache size once ready and that the allocation clears when the model stops.
  Click each model's status to open its Model Status sheet. Check live startup
  progress, cache and Local API details, the installed file action, and the
  Start on setting across a relaunch. Stop a model from the sheet and start it
  again while the sheet stays open. Verify Stop cancels chats using that model,
  including in another thread. Check Escape and Command-Q with the sheet open.
  In the composer, check that an installed, stopped local model has a play
  button to the left of the picker. Use the cancel icon to cancel startup or
  stop a running model, and verify it is disabled while stopping. Confirm that
  the send button keeps its inference stop action. Check that manual and
  first-use startup show progress in the status bar and clear it when ready,
  cancelled, or failed.
- **Browser:** Run the same flow in the staged default and
  `BROWSER_ENGINE=chromium` apps. Open Browser with Command-2, visit an HTTP or
  HTTPS test page, follow a link, and exercise back, forward, reload, and stop.
  During a slow load, verify the progress overlay stays inside the address field
  without shifting the page and clears after completion, Stop, or an error.
  Verify opening and reopening splits the workspace evenly after excluding the
  left sidebar, including after dragging the divider or resizing the window.
  Check the browser’s 320-point minimum while resizing.
  Close the last tab and confirm a centered New Tab button on the native
  selected-tab background with no tab strip or +, including after hiding and
  reopening the sidebar. Open a new tab with New Tab, switch back
  to a populated tab, and check focus and
  shortcuts with chat and the browser sidebar focused. Hide and reopen the sidebar,
  confirming tabs, page history, and the selected conversation survive. Check a refused
  connection, light and dark appearance, resize, and app quit with pages open.
  For Chromium, verify nested signatures and confirm that its helpers exit with
  the app. Check that a fresh Chromium launch can browse without a Keychain
  prompt. Check that rebuilds have distinct Keychain service/account values
  and browser profile identifiers in their Info.plist. The default bundle should
  contain no CEF framework or helpers.
- **Projects and threads:** blank sidebar and detail surfaces when no project or
  thread exists, with creation available from the toolbar and menu. Check stable
  selection, rename, New Thread/Command-N, independent transcripts and drafts,
  model settings, and launch restoration. Main chat has no tab strip. Check that
  the native right inspector opens without tabs, resizes using its divider, hides
  from the toolbar toggle, and can be hidden and reopened without changing the selected conversation. Check the panel toggle
  at minimum window width. New Chat and the panel toggle use native toolbar
  placement and styling when the inspector opens and resizes; there is no bottom panel or
  chat-tab keyboard commands.
- **Composer and chat:** model search/filter/recent choices, Return to send,
  Shift-Return for a newline, Escape to stop, Markdown rendering, scrolling,
  error feedback, and switching threads while a response streams. A new thread
  shows only the composer, without an empty conversation message.
  On macOS 26, verify that the chat header's Inferno variable Gaussian blur
  (up to 24 points at 30% opacity) affects only
  transcript content beneath it, with a gradual transition from the window top
  through 48 points below the chat heading. Text farther down stays sharp.
  Scroll text across the bottom of the heading and across message boundaries
  within the fade to check for a visible cutoff.
  The header has no horizontal divider or bar background.
  Verify that actual scrolling content extends behind the toolbar to the top
  window edge, without reflection or repetition, while foreground controls stay sharp.
  Empty space must stay clear, with no material tint. Check the top of history,
  empty chats, thread switching, and inspector reflow in light and dark appearance.
  The blur copy disables text selection so Inferno can render it as a SwiftUI
  layer; verify text and code selection still work in the original transcript.
  Check paragraphs and code blocks for shader placeholders while scrolling.
  Blur must spread past the text column's left and right edges without a hard
  cutoff, while message wrapping and alignment stay unchanged.
  Reduced Transparency fades the overlapping content without the blurred copy.
  With a long Markdown transcript, resize between minimum and wide window sizes
  and open/close the inspector, both at the bottom and while reading history.
  With the inspector closed, check that the native scrollbar sits at the right
  window edge while the messages and composer retain their insets.
  Verify messages remain visible, the latest message stays above the composer
  when following, and scrolling reaches both ends without blank overscroll.
- **Model storage:** native pop-up path control exclusively in General Settings; download setup
  shows the destination and Change opens General directly at Model Storage,
  shared persisted default across windows/relaunch, chooser cancellation, empty storage,
  Move Models/Keep Existing/Cancel with existing files, actual installed folder display,
  progress cancellation/retry, conflict and active-use errors, and Quit during a move.
- **Settings:** exactly one app-menu Settings item and Command-comma reopening the
  selected page; shared title-free unified toolbar, native traffic lights, a
  persistent sidebar without a toggle, and a rounded detail surface that begins
  below the toolbar in light/dark appearance. General appearance,
  update channel, and CLI install feedback. Models must not appear in Settings.
- **Model windows and picker:** New Local Model/New Remote Model commands and
  toolbar routes open the separate lists, including unconfigured catalog choices.
  Local Models and Remote Models use visible native window titles, toolbar search
  and actions, and standard Table appearance without duplicate content headings
  or custom footers. Local Models has no add/import/export controls; Remote Models
  owns these actions and includes API services such as Ollama. Model licenses are
  under Settings → General → Licenses, with no license links in setup/download sheets.
  A selected local model opens a content-sized native sheet with a leading-aligned
  details grid, consistent row spacing and outer margins. Model/download/memory
  records and Saving to sit inline beside Change; no grouped
  record card, redundant Not installed status, fixed-height empty area, or separate
  destination footer. Check long names, wrapped errors, linear progress, memory
  warnings, Settings navigation, Escape, and Command-Q after presentation updates.
  Local Models uses native disclosure rows for every family, including singleton
  and filtered results, and places recent selections first by default. Check
  expanding and collapsing a family, searching by family and model name, filtering
  and sorting by score, and opening setup from a child row. Search opens matching
  families by default. Folder rows have no model actions. Check compact Context
  values and their exact token counts in help.
  Check the Context column shows Automatic/maximum for chat models, with the
  latest measured Automatic fit for the selected KV cache setting.
  Start a model download, close the sheet, and check progress in Local Models.
  Reopen the sheet during the transfer and use Stop Download. Verify that
  downloading again resumes the saved bytes and closing the sheet leaves the
  chat selection alone.
  Local Models has no Provider column or provider picker in local setup/edit.
  Remote Models shows providers with recent models first in comma-separated,
  tail-truncated summaries; setup/edit/remove acts on the selected provider.
  The composer always offers Choose Model; Local and Remote filters precede
  providers and filter without opening setup. Verify ready selections, remote
  credential setup, local download confirmation, cancellation/draft retention,
  native setup/edit/download/import/export titles, forms, pickers, disclosure
  controls and buttons in light/dark appearance,
  successful setup selecting the chosen model, and decision-model exclusion from
  chat. Check blank/populated lists and model process controls (First use
  by default, App start persistence, weight load/unload, installed path and Finder
  reveal, PID, address, multi-model memory warnings including API first-use
  admission, errors, and quit cleanup), automatic Local API startup with no models,
  Service status, and
  reopening a previously selected page (including General when a saved page no
  longer exists). Omit settings pages that have no controls or status to show.
- **Providers:** combined LLM and decision provider list, add/edit/cancel, field
  labels, discovery and refresh, default/manual model choices, validation, and
  connection errors.

Check keyboard focus and command targets when moving between chat, popovers,
and Providers. Exercise accessibility or reduced-motion/transparency settings
when the changed behavior depends on them. Capture before/after screenshots
when they help review a visual change, using synthetic text and no credentials.
With an app-owned sheet open (including model setup and folder choosers), verify that Command-Q,
the app-menu Quit item, and a system Quit request terminate the staged app
without first dismissing the sheet. Repeat while the sheet has keyboard focus
or cancellable work is in progress when those states are affected.

The native composer keyboard test runs with application activation prohibited
and an offscreen panel that cannot become key, while another window contains
matching text. It dispatches events to the real owning window and verifies mention
insertion, stable references, Return-to-send, Escape dismissal, and Shift-Return,
and checks that the other window is unchanged. The composer resolves its editor
through its own containing window, so this test needs no unlocked foreground session.
A scoped event monitor excludes
unrelated desktop keyboard input, and a common-mode watchdog bounds the modal
session. The fixture restores the prior activation policy on teardown.
Keep the environment and behavior assertions when changing keyboard handling.

## Shared UI snapshots

`tests/FritzUISnapshotTests` compares the public FritzUI controls using
[swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing).
The dependency is test-only. The test harness settles native controls in an
offscreen AppKit window with
explicit appearance, sRGB color space, and a fixed 2× window backing scale. The
native window backdrop matches the hosted fixture background so translucent table
headers do not inherit the desktop appearance. It
captures a 2× bitmap and passes it directly through `assertSnapshot(of:as:)`. Comparing the
bitmap avoids resampling it at the attached display's backing scale. Fixtures set a
fixed size, English locale, light/dark color scheme, blue tint, and hidden scroll
indicators, with synthetic model/provider values and no network or credentials.
Model-download fixtures pass a fixed 32 GB Apple silicon hardware profile so
memory warnings and hardware summaries do not depend on the runner's Mac.
The fixture uses `scrollIndicators(.never)` before initial layout so SwiftUI
cannot reserve a legacy scrollbar gutter based on the user's preferences.
AppKit scroll views are also pinned to overlay scrollers.
Native table column widths are rounded up to whole points before capture to avoid
a half-point autosizing variation in header dividers across AppKit initialization contexts.

Run `make check-ui-snapshots` before committing shared UI changes. CI enables
comparison mode in the full root Swift test suite after compiling it, and
uploads mismatches from `dist/snapshot-failures`. Ordinary
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
The current references use macOS 27.2.1 (26B131), Xcode 26.6 (17F113), and
Swift 6.3.3 on Apple Silicon. The initial set used macOS 26.6.2 (25G83).
The macOS 27 refresh was reviewed against the unchanged application at 9c076a1:
image dimensions and fixture content stayed unchanged; native control tint,
disabled appearance, and glyph rendering changed. Native rendering depends on
the OS; compare on the current baseline and review intentional OS upgrades.

## Dialog snapshots

The root package and app package use the same Point-Free SnapshotTesting
image comparison and an offscreen fixture that attaches a real SwiftUI sheet
to an AppKit window. The fixture waits for stable pixels and captures the
sheet at the window's actual content size in light and dark mode. The model
download and browser dialogs change state while one sheet stays attached,
and the tests assert that the native window grows to fit new content.

The suite uses synthetic model transfers, browser profiles and account names,
project names, and stored message text. It does not read browser profiles or
Keychain items, or use the clipboard. Model provider setup and catalog download
also retain their hosted-view snapshots. System file panels, native confirmation
menus, keyboard routing, and actual window interaction require separate native
workflow checks.

`make check-ui-snapshots` compares both packages. To record reviewed app
references for an intentional change, run the app suite through the build wrapper:

```sh
mise exec -- python3 scripts/build-cache.py zsh -c '
  FRITZ_SNAPSHOT_MODE=record swift test --package-path app \
    --scratch-path "$FRITZ_APP_SWIFT_BUILD" --cache-path "$FRITZ_SWIFT_CACHE" \
    --filter AppDialogSnapshots
'
```

Set `FRITZ_SNAPSHOT_RECORD_PREFIX` inside that command or narrow the test
filter to limit recording. Follow the same before-and-after review procedure
for both packages.

Coverage includes model search, empty/no-results, recents/selection, badges,
Bedrock and generic adapter separation, horizontal provider filters, provider
categories/search, and enabled/disabled content, primary, inline, link, panel,
and toolbar buttons in
both color schemes. Floating Liquid Glass styles produce incomplete transparent
readbacks with this renderer on macOS 26; verify those styles in the staged app
instead of committing blank baselines. App-specific loading/error, streaming,
keyboard routing, and persistence
still require the native workflow checks above. Hosted form fixtures cover form content. Use the attached-sheet fixtures for
actual sheet sizing, and check shortcuts and modal shutdown in the staged app. Snapshot comparisons
complement `make test`; they do not replace those interaction checks.

If a task introduces snapshot tests, compare the affected suites before updating
references. Inspect actual, expected, and diff images. Record only intentional
changes, review them, then rerun with recording disabled. Do not loosen tolerances
or blindly regenerate baselines to make failures pass. Report the observed
workflow, test results, and any rendering/environment limitations.
