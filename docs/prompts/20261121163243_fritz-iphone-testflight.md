# Fritz for iPhone and TestFlight

> /goal Create a iPhone version of Fritz and deploy a working TestFlight

## Delegated PR verification

> Monitor the ready PR for branch codex/gabriel/fritz-iphone until the required checks conclude. Diagnose failures and fix any caused by this change. Coordinate with me before editing this shared checkout, then rerun monitoring after any push. Report the required check status with links and any blocker. Leave Apple signing and TestFlight to me.

## Follow-up PR verification

> Re-monitor PR #150 at the new head after the iOS UI test fix. Wait for the full CI aggregate, retry a failed runner if it runs out of disk, and report the result with links. Coordinate with me before editing the checkout if the change causes a failure. Leave Apple signing and TestFlight to me.

> Own the CI workflow fix and append this delegated prompt to the existing Fritz iPhone prompt log. Keep selection scoped to a supported Xcode with its matching macOS SDK and working Metal, validate the change, commit and push it to the PR, then monitor the new head to completion. Preserve the app code and dependency locks.
