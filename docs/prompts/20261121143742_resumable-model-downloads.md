# Resumable model downloads

## User requests

> inkling mini is downloading really slow... how can we download faster (find better sources) wdyt?

> let's do resumable downloads and show speed + ETA in Fritz. then benchmark parallel byte ranges vs hf-xet on the same Inkling Mini file and see which is faster.

## Delegated prompt

> Monitor the PR for codex/resumable-model-downloads in this chat's attached Fritz worktree to completion. Identify the exact head SHA and required checks. Diagnose and fix actionable failures introduced by this change, run focused local checks, commit and push any fixes to that same branch, and monitor the new head. Preserve unrelated work. Report the PR, checked head, and every final check conclusion or exact external blocker.

> Monitor the updated head of PR #146 after the accessibility follow-up. Verify the full CI result for that head and fix any actionable failures introduced by the change, then report the exact final conclusions.

## Benchmark

The 17,627,940,768-byte Inkling 2 Mini IQ4_NL at revision
`e8a2cecf0e78914f07cc27b9be711a9b2c7561d9` was fetched on an M4 Pro Mac with
macOS 27.2.1. Transfers ran sequentially without authentication or a preexisting
local model cache. Local build activity overlapped the HTTP run.

- Eight fixed HTTP ranges stalled on the last range. The initial attempt was
  stopped at 25m 34s with about 17.37 GB allocated. Retrying the final 512 MiB in
  64 MiB ranges completed the verified file in 27m 37s including recovery.
- `hf-xet` 1.8.0 high-performance mode stalled with 12.05 MB written and was
  stopped after 6m 02s. The default-mode retry used an empty cache and
  `huggingface_hub` 2.4.0. It completed in approximately 26m 02s.
- Both completed files matched the catalog SHA-256. The default Xet run was
  about 1m 35s faster than the HTTP run with recovery.

> Monitor the updated head of PR #146 after the accessibility follow-up. Verify the full CI result for that head and fix any actionable failures introduced by the change, then report the exact final conclusions.

> Please resolve on the existing PR branch in a separate temporary worktree, or coordinate before changing our attached checkout. Its local suite and staged app builds are running on fd8442e. Preserve the resume implementation and master-catalog changes, and log this follow-up if you edit the prompt record. Tell me the merge result and changed files so I can refresh the staged verification.

> The attached checkout is still in use. Please use the separate temporary checkout for the merge, push the result to the existing PR branch, and append this conflict-resolution delegation to docs/prompts/20261121143742_resumable-model-downloads.md. I’ll fast-forward our worktree after the local sequence exits.

## Merge decision

> sounds good, let's keep resumable HTTP as the default and merge #146

> Monitor PR #146 after the merge-decision documentation commit. Confirm CI for the exact new head and report its final conclusions. Fix actionable failures if needed and keep monitoring the updated head.
