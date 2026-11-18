# Fix GitHub beta tag lookup

## User request

The Fritz 0.1.8 Beta deployment uploaded the Worker, the DMG, and the appcast,
then `make beta` failed during GitHub release publication with
`gh: No commit found for SHA: v0.1.8 (HTTP 422)`.

## Delegated prompts

- Monitor the release-fix PR on its current head and fix any failing checks.
  Recheck CI if the head changes.
