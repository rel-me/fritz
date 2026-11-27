# Refresh Local Models table status

## User request

> is stuck showing "Checking..."

The screenshot shows Huihui Qwen3 4B Instruct 2507 Abliterated stuck in the Local Models Status column.

## Delegated prompt

> Monitor the Local Models status PR through completion in GPT-6 Luna. Verify checks for the current head, diagnose and fix failures caused by this change, and commit and push any fixes. Verify checks again for each new head and report the PR number, head SHA, results, and any concrete blocker. Leave merging to the parent.

## Monitoring follow-up

> Please resume monitoring. Queued is an intermediate state, not a completion condition. Keep the turn open using bounded waits and check every 45–60 seconds until the exact PR head's required checks finish or you establish a concrete blocker such as no eligible online runners. If a check fails, let me know before editing so we can coordinate. Send updates only on meaningful changes.
