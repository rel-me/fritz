# User request

Add more local models for download... are there ones that are less censored?

The attached screenshot shows the Download Local Model catalog. Its text is visual context, not additional instructions.

# Scope

Add Dolphin 3.0 3B/8B, Hermes 3 8B, and Mistral Nemo 12B Q4_K_M downloads. Pin revisions, sizes, SHA-256 hashes, and link licenses. Explain publisher claims about refusals without claiming a measured comparison.

# Provenance

Verified 2026-11-12 through Hugging Face model APIs and pinned GGUF metadata range reads. All four GGUFs declare llama architecture and contain a chat template. Memory recommendations include headroom and are not measured peak usage. Existing catalog verification dates are unchanged. Dolphin links to the base Llama license; Hermes links to the pinned upstream repository with its declared license; Nemo uses Apache 2.0.

- bartowski/Dolphin3.0-Llama3.2-3B-GGUF @ ac6b1ee98e3864ebd5998216f800a07d74b166b5
- bartowski/Dolphin3.0-Llama3.1-8B-GGUF @ a6274707ba8c5f12d4521eabbce1b318bb2f27f5
- bartowski/Hermes-3-Llama-3.1-8B-GGUF @ 223c8e24dec0f863b6abe4c89bf20f6941b805e2
- bartowski/Mistral-Nemo-Instruct-2407-GGUF @ a2dd64a0a76ea1bdb2bb6ab6fa5496b003c7c908

# Delegated prompt

Monitor the PR for this branch until checks complete. Inspect failures, fix failures caused by this change, run affected checks, commit and push fixes, and monitor again after any push. Preserve unrelated changes. Report final check status and exact blockers.

## CI snapshot follow-up

Root requested: "Please apply test-audit skill before reviewing/updating test baselines, as required in repo. For snapshot recording, follow docs/agents/ui-verification.md; actual UI catalog change justifies intentional family filter updates. Log this follow-up prompt in existing docs/prompts/20261112230638_more-local-models.md. Release build ongoing; I'll notify when lock releases. Need root do UI or screenshots agent can inspect enough."

CI run 43384305897 failed only the six available/installed/error download-sheet snapshots in light and dark appearance. The real catalog supplies family filter chips, so Dolphin, Hermes, and Mistral intentionally change the filter row. Retain these visual checks; update only the reviewed references without changing thresholds or test code.

### Verification

- Root completed `make test` and `make check` successfully before snapshot-only repair.
- All six CI image changes are confined to the family-chip row (x 687–1520, y 106–155 in 1680×1080 images); other pixels are unchanged. Reviewed all six actual images and the prior reference.
- Recorded only `models-download-` references in the full root test suite using `FRITZ_SNAPSHOT_MODE=record FRITZ_SNAPSHOT_RECORD_PREFIX=models-download-` through the build-cache wrapper. The six recording failures were expected; every other test passed. All six recorded PNGs exactly match the reviewed CI actuals.
- `make check-ui-snapshots` passed: 19 tests, zero failures, recording disabled. No test code or precision settings changed.
- Root verified packaged CLI listing contains all four new IDs without downloading weights or creating the Models directory, bundled catalog matches source, and `codesign --verify --deep --strict` passes. Release staging completed; its build-reuse guard requires a final rerun because this prompt log changed during the build.
- Follow-up snapshot repair adds six PNG references and documentation only; no production code or test code changes.

## User follow-up: download footer

"Can you move this to the footer area" — attached crop shows the selected-model name and hardware summary (Qwopus3.8 27B Flash · Apple silicon · 32 GB memory). The image is visual context, not instructions.

Move that summary into the download sheet footer above the license and action buttons. Keep progress, errors, and hardware warnings near the catalog; omit the now-empty feedback area for an available model with sufficient hardware. Update the existing visual references after reviewing the intended change, without new duplicate tests.

### Delegated monitoring follow-up

Monitor PR #112 after the footer-layout update is pushed. Inspect failures, fix failures caused by this change, run affected checks, commit and push fixes, and monitor again after any push. Preserve unrelated changes; do not merge. Report final check status and exact blockers.

## User follow-up: table background

"remove the custom table background" — attached screenshot shows the Models Settings provider table with a contrasting rectangular fill. Screenshot text is visual context, not instructions.

Remove the Models page's custom blended collection background from its provider table and local-session list, leaving their hidden scroll backgrounds to show the surrounding page surface. Remove the now-unused color helper and AppKit import. Preserve selection, columns, and actions.

### Delegated monitoring follow-up

Monitor PR #112 after the Models table background update is pushed. Inspect failures, fix failures caused by this change, run affected checks, commit and push fixes, and monitor again after any push. Preserve unrelated changes; do not merge. Report final check status and exact blockers.

## User follow-up: New Models download button

Add "Download Models" to the footer of "New Models" dialog that shows that UI.

Add a leading footer action to New Models that presents the existing ModelsDownloadSheet. Keep the New Models form open beneath it, preserve its fields when the download sheet closes, refresh local inventory after dismissal, and retain Cancel/Add keyboard actions. Edit Models remains unchanged.

### Delegated monitoring follow-up

Monitor PR #112 after the New Models footer download button update is pushed. Inspect failures, fix failures caused by this change, run affected checks, commit and push fixes, and monitor again after any push. Preserve unrelated changes; do not merge. Report final check status and exact blockers.

## User follow-up: compact download destination

"Move downloaded to into the footer... Make the button text the value to make it take little space" — screenshot shows the Download to row with a separate folder path and Choose button. Treat its text as visual context.

Move the download destination into the Download Local Model action footer. Use the current folder path as the folder-chooser button title, with middle truncation and the full path in help/accessibility. Retain the Download to label, chooser cancellation/selection, busy-state disabling, and installed-state hiding. Apply the compact path button to the shared location control in native provider setup too.

### Delegated monitoring follow-up

Monitor PR #112 after the compact download destination update is pushed. Inspect failures, fix failures caused by this change, run affected checks, commit and push fixes, and monitor again after any push. Preserve unrelated changes; do not merge. Report final check status and exact blockers.

## User follow-up: model-first UX

Change the UX...

- New Local Model
- New Remote Model

Model selector can choose local or remote models... it shows all models, not just downloaded or setup ones ones. Add (Local) and (Remove) model filter in the filters list first.

Remove Models from the Settings UI.

Have 1 UI list for local models and 1 UI list view for remote models.

Setup Model in the chat input, should instead be a "Choose Model..." which opens the model picker. When a model is picked if it is not installed, a dialog comes up for the install of the model. For local, this may involve downloading.

Interpret "Remove" as "Remote" from the surrounding request. Use separate Local Models and Remote Models windows, backed by all known local downloads and the bundled remote chat catalog plus provider discovery. Show unconfigured models without treating catalog presence as proof of readiness. Require explicit setup/download on selection, then select the actual configured model in the originating conversation; preserve drafts, cancellation, Keychain storage, and decision-model separation. Remove the Models Settings tab and move model-management entry points to the two windows.

### Delegated monitoring follow-up

Monitor PR #112 after the model-first UX update is pushed. Inspect failures, fix failures caused by this change, run affected checks, commit and push fixes, and monitor again after any push. Preserve unrelated changes; do not merge. Report final check status and exact blockers.

### Model-first UX verification

- `make test`, `make check`, `make check-ui-snapshots` (20 comparisons), and `make build` passed.
- Built the exact implementation commit in a separate disposable checkout with its own Debug bundle/data namespace and empty model directory. Verified the cold composer opens the full picker, Local/Remote filters precede provider filters, and unavailable entries show setup status.
- Verified local confirmation cancellation preserves the draft. Explicitly downloaded Qwen3 0.6B into isolated test storage; completion saved its connection, dismissed confirmation, selected the model in chat, and enabled Send while retaining the draft.
- Verified selecting Claude Sonnet 4.6 opens setup for Anthropic and that exact model, with API key required; cancelling retained the prior local selection and draft. No personal credentials were used.
- Verified Settings exposes General/Service/Debug only, File exposes New Local Model/New Remote Model, and toolbar routes open distinct Local Models and Remote Models catalog tables. Reviewed the local table without a contrasting custom fill. Verified New Remote Model form and Command-Q shutdown with its sheet focused.
- Native menu automation briefly returned stale accessibility IDs; restarted only the isolated test app and continued via the toolbar menu. Light/dark picker and setup layouts were covered by reviewed snapshots. No live model-quality evaluation was performed.

## User follow-up: remote provider rows and direct toolbar buttons

- For Remote Models list UI, don't show each model, show the providers with a list of the recent models first comma delimited and tail truncated.
- Window icon, should not have drop down.. have two icons.. first one is cpu icon for local models and other one is network icon for remote models.

Show one row per saved remote connection, plus unconfigured provider presets. Order each comma-separated model summary by recent selection, then existing catalog order; deduplicate model IDs and truncate at the tail. Preserve setup/edit/remove actions at the provider level. Replace the main window Models menu with adjacent Local Models (cpu) and Remote Models (network) toolbar buttons.

### Delegated monitoring follow-up

Monitor PR #112 after the remote-provider rows and direct toolbar buttons update is pushed. Inspect failures, fix failures caused by this change, run affected checks, commit and push fixes, and monitor again after any push. Preserve unrelated changes; do not merge. Report final check status and exact blockers.

### Provider-row follow-up verification

- `make test-swift` passed (root: 88 tests, 19 ordinary snapshot skips; app: 32 tests). `make check-ui-snapshots` passed all 20 comparisons, with existing references unchanged. `make build` passed.
- Built the implementation commit in a disposable checkout with a separate Debug bundle/data namespace. Seeded a keyless loopback mock provider; no personal connections or credentials were used.
- Verified the remote table has one saved-provider row, unconfigured preset rows, comma-separated model names, and visible tail truncation in light and dark appearance. Seeded synthetic recent selections and verified Slow Test Model and Fritz Test Model move before the remaining names. Searching by model name retains the provider row.
- Verified double-click opens the saved provider editor and cancel retains the table. Verified the CPU toolbar button directly opens Local Models and the network button directly opens Remote Models; neither is a menu. Quit the isolated app and removed its test data and checkout.

## User follow-up: local models without providers

"Make the same change for Local Models UI... Don't use provider at all... it doesn't have a provider, it is local"

Keep local records as individual models, with recent selections first and tail-truncated names. Remove the Provider column and provider-name search from the local table. Local setup/edit has a fixed implementation and no provider picker; use Default Model wording for local models and services. Keep remote provider grouping intact.

### Delegated monitoring follow-up

Monitor PR #112 after the local model-only UI update is pushed. Inspect failures, fix failures caused by this change, run affected checks, commit and push fixes, and monitor again after any push. Preserve unrelated changes; do not merge. Report final check status and exact blockers.

### Local model-only UI verification

- `make test`, `make check`, and `make build` passed. `make check-ui-snapshots` passes all 20 comparisons after reviewing and recording only six local-editor references for the intentional Default Model label change. No test code, tolerances, or new production test seams changed.
- Built the implementation in an isolated Debug checkout. Verified the Local Models table has Name, Type, and Status only in light/dark appearance. Verified Connect Local Service opens New Local Model without a provider picker; cancellation returns to the list. No weights were downloaded or provider settings saved. Quit the isolated app and removed its data and checkout.
- Final source review also removed the read-only Provider label when targeting a different model on a configured local service. Repeated the affected Swift tests, snapshot comparisons, and complete app build after that adjustment.

## User follow-up: native Local Models window

"Local Models should be window title.. use the idiomatic search and table UI for a really mac'y mac app.. no custom stuff"

Use a standard titled Local Models window, native toolbar search, the native Table appearance and selection, and native toolbar actions. Remove the duplicate in-content heading, custom search field, rounded inset background, custom button styles, and action footer from Local Models. This explicit request supersedes the repository's title-free/shared-custom-window guidance for this window. Keep Remote Models unchanged.

### Delegated monitoring follow-up

Monitor PR #112 after the native Local Models window update is pushed. Inspect failures, fix failures caused by this change, run affected checks, commit and push fixes, and monitor again after any push. Preserve unrelated changes; do not merge. Report final check status and exact blockers.

### Native Local Models verification

- `make test-swift` passed (root 88 tests with 19 normal snapshot skips; app 32 tests), `make check-ui-snapshots` passed 20 comparisons without changing references, and `make build` passed.
- Built the implementation in a disposable isolated checkout. Reviewed the visible Local Models window title, native toolbar search/actions, and standard Table selection/alternating rows in light and dark appearance. Verified typed search, native clear, double-click and toolbar setup actions, cancellation retaining search/selection, and Command-Q with setup focused. No weights were downloaded or credentials used.
- Updated repository UI guidance to preserve the explicitly requested native Local Models exception to custom Fritz window styling. Closed the test app and removed its data and checkout after verification.

## User follow-up: native Remote Models window

"Make the same change for Remote Models... window title, native search, toolbar and table UI. No custom stuff."

Give Remote Models a standard titled macOS window, toolbar search/actions, and default Table appearance, retaining provider rows with recent-first comma-separated, tail-truncated model summaries. Share the native catalog layout with Local Models and remove the obsolete custom model-window wrapper, header, search field, background, buttons, and footer. Extend the documented model-window exception to Remote Models.

### Delegated monitoring follow-up

Monitor PR #112 after the native Remote Models window update is pushed. Inspect failures, fix failures caused by this change, run affected checks, commit and push fixes, and monitor again after any push. Preserve unrelated changes; do not merge. Report final check status and exact blockers.

### Native Remote Models verification

- `make test-swift` passed (root 88 tests with 19 normal snapshot skips; app 32 tests), `make check-ui-snapshots` passed all 20 comparisons without reference changes, and `make build` passed.
- Built the implementation in a disposable isolated checkout. Reviewed the Remote Models title, native toolbar search/actions, and standard provider Table in light and dark appearance, including comma-separated, tail-truncated model summaries. Verified typed provider/model-ID search and clearing, double-click and toolbar setup actions, cancellation retaining search/selection, and Command-Q with setup focused. No credentials were entered or saved.
- Local Models still opens with its native title/search/table using the shared layout. Closed the test app and removed its data and checkout after verification.

## User follow-up: native model setup dialogs

"Make the model setup dialogs native too... standard macOS forms and buttons, no custom headers or styling."

Use native navigation titles, standard Form styles, native toolbar cancellation/confirmation buttons, menu pickers and DisclosureGroup controls in model setup/edit sheets. Remove custom palettes, headers and button styles from setup, download and import/export sheets, and use native filter pickers/table appearance in the download browser. Preserve setup/download, validation, credentials, cancellation and Quit behavior, including the compact download destination control. Remove custom header/picker/list wrappers once unused. Review intentional existing snapshot changes with test-audit; do not add duplicate behavior tests or relax tolerances.

### Delegated monitoring follow-up

Monitor PR #112 after the native model setup dialogs update is pushed. Inspect failures, fix failures caused by this change, run affected checks, commit and push fixes, and monitor again after any push. Preserve unrelated changes; do not merge. Report final check status and exact blockers.

### Native model dialog verification

- `make test`, `make check`, `make check-ui-snapshots` (20 tests), and `make build` passed. Reviewed all 26 changed setup/editor/download images in light and dark appearance, recorded only the `models-` and `model-setup-` families, and verified the recorded PNGs match the reviewed actuals. Test code and precision thresholds are unchanged.
- Native titles/actions are outside the hosted-view bitmap; the retained snapshots independently guard form/filter/table/status content. Verified titles, standard Cancel/Add/Save/Download/Done buttons, provider menu picker, Advanced disclosure and model search in the staged app instead of adding test-only rendering seams.
- In an isolated Debug checkout/data namespace, created a keyless OpenAI-compatible connection against the local mock provider, discovered four models, edited its name through Advanced and saved successfully. Verified nested native model-sheet search and Done, import validation/Cancel, keyless export/Done, and light/dark setup appearance. No personal credentials were used.
- Chose isolated TestModels storage through NSOpenPanel, downloaded Qwen3 0.6B, and verified completion automatically saved setup and returned the model as Ready. Cancelling another model's setup left it uninstalled. No model-quality evaluation was performed.
- Command-Q closed the native setup sheet normally. Its delivery while the native file panel had focus could not be confirmed through automation. Read-only LLDB inspection of the verified test process showed the app active, the setup/panel termination flags disabled, and the app-menu Quit action enabled. No speculative command-routing workaround was added; file-panel shortcut automation remains a verification limit.
- Closed the test app, stopped the mock provider, and removed its test data, downloaded weight, and disposable checkout. Updated the native sheet API documentation and snapshot-scope guidance.

## User follow-up: local-only downloads and Settings licenses

For local models remove plus ... dropdown import... those are only for remote...
Remove "Model license" button, put those buried in Settings.
Ollama and stuff like that should fall in "Remote Models"

Keep only model setup and native search in the Local Models toolbar; add/import/export belong to Remote Models. Treat API services, including localhost Ollama, as remote in catalog lists, provider presets/badges, and chat location filters. Only Fritz-managed native chat/decision downloads remain Local. Remove model license links from setup/download surfaces and put the pinned model links under General → Licenses → Local Model Licenses in Settings, alongside the Ollama library link. Preserve endpoint IDs, credentials and installed files.

Use test-audit for the updated category contract and the picker-boundary location test. The latter failed on the prior Ollama-is-local behavior before implementation. It independently protects chat filtering, while the existing category test protects provider/window classification; neither adds a production seam.

### Delegated monitoring follow-up

Monitor PR #112 after the local toolbar, Settings licenses and service classification update is pushed. Inspect failures, fix failures caused by this change, run affected checks, commit and push fixes, and monitor again after any push. Preserve unrelated changes; do not merge. Report final check status and exact blockers.

### Local toolbar, service classification and license verification

- The existing provider category test and new picker-boundary test pass; the latter first failed on Ollama's previous Local classification. `make test-swift` passes with 89 root tests and 32 app tests.
- Reviewed the 12 changed light/dark setup/download/editor snapshots, recorded only those families, and byte-compared references to reviewed actuals. All 20 snapshot comparisons pass without precision changes.
- Built and launched an isolated staged app. Local Models exposes only setup/search, lists native downloads, and has no plus or More/import/export. A synthetic keyless Ollama connection against a local mock remains Ready in Remote Models, which retains New Remote Model and import/export. No personal credentials were used.
- Opened Qwen3 0.6B setup and verified the license link is absent while the destination control and Cancel/Download actions remain. General Settings starts with Licenses collapsed; expanding it reveals Local Model Licenses and the Ollama library, and expanding the nested disclosure shows the pinned catalog license links. No license URLs were opened and no weights were downloaded for this check.
- Quit the isolated app normally, stopped the mock, and removed the isolated data and disposable checkout. Chat location behavior is covered by the picker-boundary test; it was not additionally exercised in the running app for this follow-up.
- Final full `make test`, `make check`, `make check-ui-snapshots`, and staged `make build` passed. Reviewed the diff and `git diff --check`; no unrelated files were changed.

## User follow-up: repair CI and reclaim runner build storage

"Fix CI"

"Clean up old build artifacts on runner-mac-mini-4 (1,2,3,4) and rerun CI."

Original CI failed before tests with ENOSPC during Python installation on runner-mac-mini-4. Attempt 2 was cancelled; attempt 3 was restarted and passed tool installation. Inspect runner 1–4 output ownership/activity/locks before removing disposable generated builds. Preserve sources, credentials, toolchains, active jobs, locks and unresolved evidence.

Delegated monitor: monitor run 43690324734 attempt 3 without duplicate reruns/cancellations; report setup progress and actual failures, preserve all checks and unrelated changes. Root is locating runner access and performing the requested cleanup.

### Runner cleanup outcome

- Connected to the existing known SSH host as `runner-ci`. Inventoried runners 1–4 and Fritz's CI output layout. Runner 1 had no matching runner output tree; runner 2 was actively executing this PR's CI and was preserved. Current toolchain outputs and shared package/compiler caches were preserved.
- Removed generated Cargo debug/tmp, Swift scratch, app Swift scratch and DerivedData children only from runners 3 and 4's old `60161568860ed86d308b4a2e2858ea91aa869b7d132d3b281c2b411cf7665750` toolchain trees. Runner keys were validated against the workflow's SHA-256 naming and checkout hashes against build-cache.py. Previewed about 21.2 GiB of logical output.
- Acquired existing checkout locks followed by the root output lock for each tree; revalidated owner, physical directory identity, active processes and open files before deletion. Retained all lock/socket files and directory ancestry required by retained locks. No source checkout, credentials, active job, toolchain, reusable cache or investigation evidence was removed.
- Free space was initially about 12 GiB, then 22 GiB immediately before application (other activity changed availability). After cleanup it was about 41 GiB, an observed increase of about 19 GiB during application. Stopped at that point.
- CI attempt 3 had passed setup, tests and Rust checks and reached both-browser builds before cleanup completed. Push this required prompt log to the existing PR to start fresh CI after cleanup. No product or test code change was needed; no new PR is created.

Delegated monitoring after cleanup push: monitor PR #112 at the new head through completion; inspect actual failed jobs, repair attributable failures with focused validation and commit/push if needed, and monitor every subsequent push. Do not merge or make duplicate reruns. Report final checks and exact blockers.
