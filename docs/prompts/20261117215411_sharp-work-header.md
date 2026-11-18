# Sharp work header

## User requests

> the response header is blurred why?

The first request included a screenshot showing “Worked for 38s” above a sharp response body.

> It looks blurred in the live app too. Can you reproduce it and fix the “Worked for” header so the text renders sharply?

## Delegated PR monitoring prompt

Monitor the ready PR for `codex/sharp-work-header` until checks finish. Diagnose and fix any failure caused by this change, preserving unrelated work. Use repository build targets and applicable skills. If you change the PR, record the follow-up work in this prompt log, commit and push, and monitor the new head again in a sub-agent. Do not merge. Report exact check results and any blockers.

## Verification

- Compared the baseline and rebuilt native Debug app with isolated synthetic transcripts on macOS 27.2.1 in dark appearance. Reproduced a difference in the activity label as its row crossed the toolbar boundary. At rest, labels and response text well below the toolbar matched in the captures.
- Checked collapsed and expanded tool activity, text-only elapsed time, the toolbar fade during scrolling, inspector reflow, empty chat, and a completed response through the keyless mock provider. Light appearance, Reduced Transparency, and fullscreen were not exercised.
- `make build`, `make -j2 test check`, and `git diff --check` passed.
