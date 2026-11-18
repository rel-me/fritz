# Models toolbar filters

## User request

> the local and remove models list UI showing this weird loading button.. remove it..
>
> also change the filter button to actually show filters on the models (LLM, Decision, Downloaded, etc)
>
> for edit action, show the edit icon not sliders...

The attachment shows a spinner in a pill-shaped toolbar item. “Remove models” refers to Remote Models.

## Delegated PR monitoring prompt

Monitor the ready PR for `codex/models-toolbar-filters` through completion. Diagnose and fix failures attributable to this change. Use repository checks and applicable skills. If the PR head changes after a successful run, arrange fresh sub-agent monitoring for that head. Log any follow-up prompts here. Report exact check results and blockers. Do not merge.

## Verification

- Passed `make build`, `CONFIGURATION=release make build`, `make -j2 test check`, and all 21 cases in `make check-ui-snapshots`.
- In the staged app on macOS 27.2.1 in dark appearance, verified both toolbars, local download status for synthetic LLM and decision model files, combined filters, empty search results, remote model types with a keyless mock provider, both pencil actions, and Command-Q from the provider editor.

## Follow-up user request

> the remote model is showing a horizontal scroll on load, we don't want that

The attachment shows the horizontal scrollbar at the bottom of Remote Models.

## Follow-up delegated monitoring prompt

Monitor the updated head of PR #125 until CI completes. Diagnose and fix failures attributable to the change. Preserve unrelated build caches and runner infrastructure. Report exact check results and any blockers. Do not merge.

## Follow-up verification

- Debug and Release builds passed. All 21 UI snapshot tests passed.
- The isolated Release build with a mock provider showed all three Remote Models columns at the default and a narrower window width, with long model summaries truncated and no horizontal scrollbar. An empty search also showed no scrollbar.

The user confirmed that they cleared disk space after the initial verification build hit a disk-space error.
