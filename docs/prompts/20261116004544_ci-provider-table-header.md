# User request

Review PR112 (codex/gabriel/more-local-models → main) and make the smallest safe fix for the attached failing CI. Inspect latest GitHub runs, annotations and logs before changing code; use GitHub CLI with the explicit repository. Verify narrowly, commit and push.

# GitHub evidence before edits

- Confirmed this checkout is on PR112's branch at affba4decbd622c48069e56495d53ebe3064a51c with a clean working tree.
- Attached run43831162205 at931b539 failed exactly four assertions in SharedControlSnapshots/testModelProvidersList: standard and compact provider tables, light and dark. Its aggregate Libraries/app/runtime job failed only because the upstream result was failure.
- Later completed run43832750936 atcf5b034 has the same four assertion failures. Latest run43833611722 ataffba4d was still in progress at inspection.
- Read both failed job logs using gh run view and inspected annotations via the GitHub API. The API command has no --repo flag, so it used an explicit repos/rel-me/fritz endpoint and GH_REPO instead. Nonfatal Node-action deprecation and cache-restore warnings did not cause these assertions.

# Delegated repair prompt

Continue the existing monitoring agent's cross-host investigation of the four provider-table header-only rendering mismatches in its disposable checkout. Preserve root changes; use GitHub logs/artifacts as source of truth. Find a narrow deterministic fixture repair, validate locally and on the affected runner through existing wrappers/session locks, review changed references if necessary, and commit/push to PR112. No tolerance changes, skipped tests, production-only test seams, global preference changes, duplicate CI runs or merge. Coordinate before publishing. Monitor the new head and repair attributable failures after each push.

# Test scope

Reuse the existing native table snapshots, whose owning fixture controls appearance, display scale and scroll geometry. Do not introduce duplicate tests or change production UI merely to accommodate runner rendering. Investigate public AppKit backing/appearance/material state before recording any references.

# Rejected candidates / evidence

The delegated probe reproduced the exact four failures in an isolated runner checkout through the CI wrapper/session locks. Explicit Aqua/darkAqua header appearance, 2x layer backing and a private nonvibrant native header subclass did not pass old-reference comparisons and were not retained. Subsequent validation review required fresh cross-host image comparisons before drawing conclusions about those candidates. Diagnostic state matched for table style, header background style, transparent table background, app activation, screen scale, contrast/reduced transparency, frames and fonts. Do not retain unsuccessful normalization or diagnostics in the repair.

The latest affba4d run43833611722 completed with the same four assertions on runner-mac-mini-4 (the original run used runner2). Per-job failed logs were inspected after the job completed; while in progress, GitHub explicitly reported logs unavailable even for that job. No new runtime/compiler failures appeared.

Cross-host diagnostics then found a concrete missing input: native window/control background colors resolved under the desktop's ambient current drawing appearance rather than the fixture's requested appearance. Local color resolution stayed dark in both fixtures; remote stayed light in both. The next repair candidate scopes native rendering with the public NSAppearance drawing API, which restores the previous drawing appearance without changing global preferences.

# Validation correction

Failure counts against the old references did not establish whether a rendering-normalization candidate matched across hosts. Require fresh local and remote captures from the same candidate, compare their image hashes/pixel deltas directly, and record the candidate source hash. Only then compare/review any intended baseline updates. Fixed backdrop diagnostics showed partial improvement (dark header31→68 versus the previous CI67), motivating explicit transparent/nonopaque window capture rather than blindly changing header pixels.

# Verified repair

The fresh fixed-backdrop candidate matches all four local/runner PNGs byte-for-byte (zero differing pixels), recorded in /tmp/fritz-header-fixed-crosshost.json. Set the offscreen native window background to the same explicit darkGray/white backdrop already used by the hosted snapshot. This removes the ambient desktop backdrop from native header compositing while preserving native drawing. Root reviewed all four candidate images and the one-property fixture change. No product UI, tolerances, exclusions, global preferences, or rendering overrides are needed. Remove all diagnostic probes and rejected candidates before committing.

# Final verification

- Reviewed four fixed-backdrop light/dark, standard/compact references; no record/column/label/selection/clipping changes. All four fresh local and runner images match byte-for-byte.
- After removing diagnostics, normal targeted comparisons passed on both hosts (logs /tmp/fritz-header-final-local.log and /tmp/fritz-header-final-remote.log).
- The agent's integrated21 comparison passed, then the root PR checkout independently passed all21 tests with zero failures (/tmp/fritz-pr112-header-final-compare.log). git diff --check passed.
- This fixture-only repair does not change production UI or runtime. Existing runtime/build validation at affba4d remains unchanged; the relevant snapshot checks were rerun for this repair.
- Root publishes the focused commit; the existing monitoring sub-agent continues PR112 checks and repairs attributable failures after every push. No merge requested.
