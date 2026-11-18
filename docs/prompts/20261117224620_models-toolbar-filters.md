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
