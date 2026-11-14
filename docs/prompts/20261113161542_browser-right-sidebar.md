# Browser in the right sidebar

## User request

> Where is the webview in Fritz right now. Lets place it in the right sidebar.

Follow repository instructions to create a branch, commit, push, create a ready PR,
and delegate PR monitoring and failure fixes to a sub-agent.

## Delegated prompts

Monitor the ready PR for branch `codex/gabriel/browser-right-sidebar` in
`rel-me/fritz` until checks finish. Fix failures caused by this change, run
appropriate local checks, commit and push fixes, and monitor the updated PR
again. Preserve unrelated changes. Append any additional delegated prompts to
this prompt log. Report final check results and exact blockers. Do not merge.


## Follow-up user request

> Remove the browser header completely. Also allow the last tab to be closed leaving a + icon behind and an empty view.

## Follow-up delegated prompt

Monitor PR #113 again after the follow-up commit removing the browser header
and allowing an empty tab strip. Fix failures caused by this change, run
appropriate local checks, commit and push fixes, and monitor the updated PR
again. Preserve unrelated changes and do not merge. Report final checks and
exact blockers. Append additional delegated prompts to this prompt log.

## Follow-up user request

> I think the right sidebar should have a min width and when opened it should take 50% of the width of the window not counting the left sidebar.

## Follow-up delegated prompt

Monitor PR #113 again after the sidebar sizing follow-up. Fix failures caused
by this change, run appropriate local checks, commit and push fixes, and monitor
the updated PR again. Preserve unrelated changes, do not merge, and report
final checks and exact blockers. Append additional delegated prompts to this
prompt log.

## Follow-up evidence

The user attached a crash report for FritzWebViewDebug113 during sidebar sizing
verification. The report showed an AppKit maximum-size constraint failure.
Investigate and fix the launch crash as part of this sizing change.

## Follow-up user request

> On empty view (no browser tabs), show a "New Tab" button in the center. Remove the custom background color. Remove the + in tab view when no tabs..e.g. just show the empty view with "New Tab" button.

## Additional monitoring scope

The same follow-up also changes the empty browser state to a centered New Tab
button without a tab strip, + control, or custom background. Monitor these
changes together with the proportional sidebar sizing in PR #113.

## Follow-up user request

> Empty tab should have the tab background... the tabview horizontal view should have a clear background (just shows the tabs)

Apply the selected-tab background to the empty browser area and blank tabs,
with a transparent horizontal tab strip. Include these visual changes in the
same PR monitoring scope.
