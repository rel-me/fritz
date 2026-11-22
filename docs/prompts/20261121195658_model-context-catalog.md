# Model context limits in the catalog

## User request

> We need to know the context size max for every model as part of the catalog.. I think sometimes we might only have a range initally but do your best.. it might be dynamic and we need to check the remote for remote providers.

## Delegated prompt

> In GPT-6 Luna, monitor the model context catalog PR through completion. Investigate failed checks, land scoped fixes as needed, and monitor each new head until the required checks pass or infrastructure blocks verification.

## Follow-up prompt — 2026-11-21 20:15 PST

> Diagnose the failed Mac CI on the current PR head, identify the runner's selected Xcode, and add a scoped workflow recovery for the missing Metal toolchain. Prefer a verified Swift 6.3 Xcode to preserve the committed Swift package lock graph; download Apple's MetalToolchain component only when the compiler check fails. Keep the repair workflow-only, preserve committed lockfiles, and monitor each replacement head until required checks conclude.
