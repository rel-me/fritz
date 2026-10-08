# OpenAI model capabilities

`Sources/Fritz/ModelCatalog.json` is the bundled source for OpenAI chat model
names, reasoning efforts, and selectable speeds. Swift loads it as a package
resource; Rust embeds that same file in its request builder. Discovery controls
which models the account can use. Catalog entries do not add connections or
grant model access, and do not apply to OpenAI-compatible endpoints or Decisions.

The schema has `schemaVersion: 1`, a positive catalog `revision`, a `reviewedAt`
date, and `models` keyed by exact API ID. Bump `revision` for content updates;
change `schemaVersion` for incompatible format changes. Each entry has
`displayName`, `status`, ordered `reasoningEfforts`, ordered `speeds`
(`standard`, `priority`, `flex`), `defaultReasoning`, and `defaultSpeed`.
`priority` is labeled Fast in the app. Defaults must belong to their capability
lists. `defaultReasoning` is required and null only when `reasoningEfforts` is
empty; otherwise the current default is `medium`. The current default speed is
`standard`. New selections use these defaults; supported saved choices survive
catalog refreshes and model changes.

Status is one of `active`, `deprecated`, or `retired`. Active entries are
recommended normally. Deprecated entries remain selectable and usable but are
excluded from automatic recommendations. Retired entries are excluded from
discovery and the chat picker, including manually configured choices; explicit
chat requests fail with an actionable retirement error. Keep retirement entries
in the catalog: deleting an entry instead makes its ID unknown and conservatively
selectable again. Status does not delete connections, transcripts, or preferences.
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

## Supplemental metadata and pricing

The same file includes `model_info`: full provider/model metadata imported from
Models.dev, with USD-per-million-token prices and import provenance. Refresh it
with `python3 scripts/update-model-catalog.py` and review the diff. Imports preserve
`reviewed_openai` and the verified-model inventory; they never enable optional
request parameters or mark a model verified. The Rust request builder and Swift
controls continue using the same bundled reviewed capabilities.

`RemoteModelCatalog` seeds from this bundled file and revalidates supplemental
metadata at `https://rel.me/supported-models.json` on each Models load. Provider
APIs still determine availability; metadata lookup never adds an account's models.
Concurrent loads share one bounded-time request. ETag / If-None-Match avoids
redownloading unchanged data, with Last-Modified used when ETag is absent. Valid
responses atomically replace a host-supplied cache, preserving the complete JSON;
errors retain validated data and remain available through the catalog's `error`.
Hosts supply isolated cache paths. Without a path, the cache lives in memory.

`web/model-catalog.mjs` serves the canonical file with a content-derived ETag and
conditional GET/HEAD support. It also exports `serveModelCatalogPage` for a minimal
HTML view at `/catalog`, including filtering and expandable full model metadata.
The rel.me host mounts these exported handlers; deployment belongs to that host. Clients never query
Models.dev. Before that host adopts the new representation, remote refresh reports
a schema error and the explicitly bundled metadata remains available.

Use official docs as evidence, not model-name guesses or automatic paid probes.
Run `make test`, `make check`, UI snapshot comparisons, and the staged native
picker workflow when changing capabilities or presentation.
