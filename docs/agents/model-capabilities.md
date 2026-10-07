# OpenAI model capabilities

`Sources/Fritz/OpenAIModels.json` is the bundled source for OpenAI chat model
names, reasoning efforts, and selectable speeds. Swift loads it as a package
resource; Rust embeds that same file in its request builder. Discovery controls
which models the account can use. Catalog entries do not add connections or
grant model access, and do not apply to OpenAI-compatible endpoints or Decisions.

The schema has `version: 1`, a `reviewedAt` date, and `models` keyed by exact API
ID. Each entry has `displayName`, ordered `reasoningEfforts`, and ordered
`speeds` (`standard`, `priority`, `flex`). `priority` is labeled Fast in the app.
Newly reviewed entries also link to the official model documentation in `source`.
Established entries preserve the subset of options previously offered by Fritz;
verify documentation before expanding those options. Snapshot IDs and aliases
require their own entries rather than inheriting capabilities by name prefix.

To add a model, verify its official API documentation and processing-tier
availability, add the exact ID, and exercise both the picker and request body.
Keep IDs unchanged in requests and saved preferences. Provider-supplied friendly
names are preserved; raw GPT IDs get readable labels even without a catalog
entry. Unknown IDs can be selected and sent without optional reasoning or speed
parameters. Explicit unsupported parameters produce an error rather than being
silently discarded. Refreshing discovery updates metadata for saved selections.

## Proposed rel.me distribution

A versioned static endpoint such as `https://rel.me/fritz/models/v1.json` could
publish this format to update capabilities between app releases. It is not
deployed or fetched by Fritz today. Introduce remote refresh as a separate
runtime change: HTTPS, bounded downloads/timeouts, schema and value validation,
reviewed or signed releases, and an atomic last-known-good cache with the bundled
catalog available offline. One Rust-owned catalog version must supply metadata
to Swift and validate the harness request, so a refresh cannot leave the UI and
request builder using different rules. Unknown enum values or schema versions
must not silently enable controls. Keep API endpoints, credentials, executable
code, and account/model selection out of catalog updates.

Use official docs as evidence, not model-name guesses or automatic paid probes.
Run `make test`, `make check`, UI snapshot comparisons, and the staged native
picker workflow when changing capabilities or presentation.
