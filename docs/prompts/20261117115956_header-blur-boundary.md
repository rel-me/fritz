# Header blur boundary

## User request

> The blur should only be applied at top of header.. it is currently down in the content view\... remove the horizontal divider from the header area doo

## Repository instructions

Create a branch and ready PR, commit and push the change, and delegate PR monitoring and failure fixes to a sub-agent. Record the user request and delegated prompts here.

## Delegated PR monitoring prompt

Monitor the ready PR for `codex/gabriel/header-blur-boundary` until its checks finish. Inspect failures and fix failures caused by this change. Preserve unrelated work. Use the repository's build wrapper and applicable skills. If you change the PR, append your work and any delegated prompts to this prompt log, commit and push, then monitor the new head again until checks pass. Do not merge the PR. Report check results and exact blockers.

## Verification

- `make build` passed, staging and signing the complete checkout-specific Debug app.
- Native UI exercised with synthetic persisted Markdown paragraphs and code blocks plus a keyless local mock provider: light/dark appearance, empty chat, thread switching, scrolling to the top and bottom of history, and inspector open/close reflow. The blur transition ends inside the measured header; content below stays sharp, and the horizontal divider is absent.
- Settings appearance restored to System and the staged preview app quit with Command-Q.
- `git diff --check` passed. No shared library controls or tests changed. Fullscreen, Reduced Transparency, minimum-width resizing, streaming, and error-state UI were not exercised.
