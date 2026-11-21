# Master model catalog

## User request

> Can you create 1 master catalog, and have it hosted at [https://fritz.rel.me/](https://fritz.rel.me/) somewhere... and then have a web page that shows the web version of the catalog... and then we can include that catalog in the fritz build... this way we have 1 catalog used everywhere. Create a version in the catalog and increase it each time we change it.

## Follow-up

> authorized

## Delegated prompt

> Monitor the master-model-catalog PR on GitHub through a terminal result for all checks. Diagnose and fix any change-related failures, commit and push focused fixes, and monitor the new head. Coordinate with me before editing while my local checks are running. Report the final head, check results, and any external blockers. Do not merge or deploy.

## Delegated follow-up

> Local make test found Historical transport core changed in test_bosun_browser_pairing.py. Please fix this failure now in the evaluation tooling, preserving the historical transport core digest and support for the new master catalog in current evaluation callers. The queued local check/build can continue since they do not read the affected Python tests. Append this prompt to the change's docs/prompts file, commit and push, then monitor the updated head.
