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
