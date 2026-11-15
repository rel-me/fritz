# User request

Apply idiomatic native macOS UI conventions to REL-owned windows and dialogs and preserve the existing architecture, functionality, engine and data. Use native titles, toolbars/search/buttons/menus/List/Table/forms/menu pickers/disclosures; remove duplicate headings and decorative cards, filters, backgrounds and button wrappers. Preserve selection, drafts, focus, accessibility, validation, default/cancel actions, progress and cancellation. Keep native file choosers and normal Quit while sheets, choosers and downloads are open. Keep local models as individual records without Provider column, and remote models grouped by provider with recent model names first in comma-separated single-line tail-truncated summaries. Capture before/after pictures, build/exercise isolated apps without personal credentials, review snapshot changes, commit/push and open ready PRs; do not merge.

# Explicit follow-up

Prepare an upstream Fritz PR too for the shared Models and integration screens. REL refreshes Fritz main before supported builds, so the upstream change must land separately before REL can consume and verify it. Do not merge.

# Delegated PR monitoring

Monitor the final upstream Fritz PR and REL PR #890 after the primary supplies their URLs and final commit heads. Read repository CI instructions, wait for checks, diagnose failures, and coordinate any fix with the primary before editing the shared checkout. Do not edit or change Git during the primary's builds and checks. Never merge. Re-monitor any changed PR head.

# Delegated rebase and conflict resolution

Rebase only the two native UI commits e5bc409 and 97cb5b6 (base b86a204) onto origin/main 41c1271 to fix PR #114’s merge conflict and restore pull_request CI. Preserve upstream functionality/build settings; retain native UI guidance and the upstream Browser verification section; regenerate the Xcode project from merged project.yml. Do not push before primary review and verification. Continue monitoring REL #890 read-only.

Rebased the two commits onto 41c1271510d24bf6d32402e394e6fb896a475d74. Resolved UI verification documentation by retaining the native title/toolbar guidance and all upstream Browser checks. Regenerated app/Fritz.xcodeproj from the unchanged upstream app/project.yml with the pinned XcodeGen, retaining conditional browser build settings and source files. The regenerated project removes only obsolete UI wrapper source references. No upstream browser, inference, packaging, dependency, or runtime changes were reverted. Prior build/test evidence predates this rebase; the primary must rerun the affected checks and staged build on the rebased source before publishing.
