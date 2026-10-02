# App / agent protocol

The app launches the bundled `fritz --agent`. Each stdin line is a JSON request with a unique `id`, `method`, and `params`. Each stdout line is an event carrying the same request `id`. No network listener is opened. The process exits when stdin closes.

| Method | Parameters | Result |
| --- | --- | --- |
| `health` | `{}` | Agent name and version |
| `providers.list` | `{}` | Registry |
| `providers.save` | `connection`, optional `apiKey`, `makeDefault` | Updated registry |
| `providers.import` | `providers`: array of `connection` and optional `apiKey` | Updated registry; permits missing keys |
| `providers.migrate` | `migrationId`, `providers` containing `connection` and optional `credentialSource` (`service`, UUID `account`), optional `defaultConnectionId` | Original-to-destination UUID map (`connectionIds`) |
| `providers.migrationStatus` | `migrationId` | `migration`: committed UUID map or null if incomplete |
| `providers.remove` | `id` | Updated registry |
| `providers.default` | `id` | Updated registry |
| `models.list` | `connectionId`, or draft `connection` and optional `apiKey` | `models` array |
| `localModels.list` | Optional `modelId` | Pinned catalog entries with `id`, `name`, `size`, file-presence `installed` status, and `path` (installed GGUF path or null) |
| `localModels.install` | `modelId` | Download progress, then `modelId` and `installed: true` |
| `chat` | `connectionId`, `model`, `messages`, optional `effort`, `speed` | Stream, then empty result |
| `decisionModels.list` | Optional `modelId` | Pinned local decision catalog, file-presence installation status, and `path` (installed ONNX graph path or null) |
| `decisionModels.install` | `modelId` | Explicit verified download, progress events, and installed result |
| `decisions.evaluate` | `connectionId` and `request` (`state`, `model`, `questions`); or explicit `backend`, `apiKey`, and `request` for host integrations | One typed decision result from the separate harness |
| `cancel` | `requestId` | Cancels request and returns empty result |

A connection contains `id` (UUID), `name`, `provider`, `baseUrl` (optional), and `modelId`. A chat message contains `role` (`user` or `assistant`) and `content`.
TypeSafe connections retain the wire identifier `jev` for compatibility, use model `jev-latest`, and have no configurable endpoint. Providers have LLM or Decision model categories. Only LLM connections can be the default chat provider or be used by `chat`.

Provider import validates every connection before saving, then saves in order. A storage or Keychain failure reports how many entries were saved. Missing keys are allowed during import and discovery reports that setup is needed. Existing keys are preserved when omitted; changing an endpoint with a saved key requires a replacement key. Saving or importing rejects another connection with the same provider kind and endpoint, or the same Fritz/Ollaya local model. Existing default selection is preserved; the first LLM becomes default if none exists. The UI resolves Skip/Overwrite by service, preserving existing IDs and connection names, and refuses ambiguous overwrites. Export is a UI operation: metadata is encoded as version 1 `fritz.provider` or `fritz.providers` JSON; the importer also accepts REL's corresponding envelopes. An explicit key-inclusive export reads Fritz's Keychain in the app process, never through an agent response.

Provider migration is a one-time host import with no API keys in its payload or result. Rust copies the referenced Keychain items into the destination namespace without deleting the sources or replacing existing destination keys. The full batch is validated before copying. Provider records, default selection, UUID mappings, and completion commit in one SQLite transaction. A credential/storage failure leaves the migration incomplete and retryable. Already configured connections are preserved; duplicate targets map to the existing UUID. Name or identity conflicts with a different target stop the migration. An existing default is preserved; otherwise the imported LLM default is selected. Retrying a completed `migrationId` returns the original mapping without reading source credentials or overwriting subsequent user changes.

Events are `delta` with `text`, `usage` with provider usage metadata, `result` with `result`, `error` with `message`, or `cancelled`. `result`, `error`, and `cancelled` terminate the corresponding request. Registry writes run in arrival order; discovery and chat run asynchronously. The protocol never returns a saved API key. Credentials are passed only over the private input pipe.

Local installs also emit `progress` with `status` (`checking`, `downloading`,
`ready`), `downloaded`, and `total` byte counts. `ready` precedes the terminal
result; it is not itself a completed request. `cancel` aborts a download and
removes its partial file. Retry starts a fresh download. A killed process may
leave a bounded partial file; the next explicit install replaces it. Only files
with the catalog's exact size and SHA-256 are atomically published and loaded.

The `fritz` provider has no endpoint or API key. `models.list` returns its
present model files. Listing, saving a connection, and chatting never
implicitly download weights. Local chat streams `delta` and `usage` events
through the same pipes as remote providers. Each request loads weights in its
own harness process; closing its pipe cancels the run. The local model is
limited to 8,192 context tokens and 2,048 output tokens per turn.

Fritz local models use the shared harness tool loop when a project folder is
attached. The pinned GGUF runs in process through mistral.rs. Catalog models
marked to disable thinking use reasoning effort off; tool choice is automatic.
Structured calls and tool results remain
in model-native history for the next turn. Without a project, no tools are sent.

`fritz local-models serve` exposes loopback-only Ollama-shaped `/api/tags`,
`/api/chat`, and `/api/generate` routes. CLI listeners retain one model between
requests and remain owned by their CLI process. Fritz starts one shared listener
at app launch, even without installed models, with a free loopback port. The
address and PID appear in Settings → Service and the model editor. Chat and
agent requests keep their existing private pipes and do not use this listener.

The app passes `--managed` and supervises the listener over private stdin/stdout
pipes. Stdin accepts NDJSON `{ "action": "start" | "stop" | "deny", "modelId": ID }`.
`start` loads and retains weights; `stop` cancels its active API request and
unloads that model, leaving the API running; `deny` cancels a pending first-use admission. Stdout emits
`{ "type": "service", "address": URL }`,
`{ "type": "model", "modelId": ID, "status": "starting" | "running" | "stopped" | "failed", "error"?: MESSAGE }`,
and `{ "type": "loadRequested", "modelId": ID }` when an API request needs
unloaded weights. That request waits for app admission before loading. The
service reports Running only after the native loader succeeds. Failed loads
return a model error and leave the API available. Managed listeners can retain
multiple models; inference remains serialized.

New Models and Edit Models expose Download, Start/Stop, and Start on for Fritz
chat models. Startup policies live in the workspace database. First use is the
default and loads on the first API request; App start preloads saved Fritz
connections. Explicit starts and first-use admissions check catalog memory
recommendations and current available RAM, warning before another model loads
when the estimate is tight. Closing the owner pipe or quitting the app stops
the listener and unloads its models. Deleting or changing a connection unloads
its old API model. Chat and decision harness ownership remains unchanged.

## Decision harness

`fritz-decision-harness evaluate` accepts one private NDJSON line with a typed
`request`, `backend`, and optional `apiKey`. It returns one terminal `result`,
`error`, or `cancelled` event. The backend does not produce chat deltas or execute
folder actions. Closing stdin cancels it. The [decision-harness guide](decision-harness.md)
documents its contract, Jev adapter, Ollaya local backend, and how to pair a
judgment with a separate conversational run.
The agent's `decisions.evaluate` method supervises this child and returns its
typed result under the request ID. For a saved Jev `connectionId`, the agent
retrieves its key from Keychain and passes it to the child over the private
pipe. Host integrations can still supply explicit backend input and an `apiKey`.
Neither path returns the key.

## Chat harness (protocol version 2)

`chat` additionally accepts `projectPath` (an absolute existing directory) and
`maxTurns` (1–40, default 24). There is no separate assistant mode field. The app sends
the directory belonging to the request's thread, not whichever project happens
to be selected when a response arrives. The CLI resolves `--project` to an
absolute path. Remote requests with a project advertise file and command tools;
requests without a project use the same loop without tools. Unsolicited tool
calls without a project fail before execution. Legacy `mode` fields are ignored.

Every conversation runs in a bundled sibling executable, `fritz-harness chat`. The
service resolves the saved provider and key, then writes exactly one NDJSON
line to its private stdin:

```json
{"request":{"connectionId":"UUID","model":"model-id","messages":[{"role":"user","content":"Summarize my notes"}],"projectPath":"/path/to/notes","maxTurns":24},"connection":{"id":"UUID","name":"Example","provider":"openai-compatible","baseUrl":"http://localhost:8000/v1","modelId":"model-id"},"apiKey":null}
```

`apiKey` is either null or a secret transmitted only over this pipe. Never put
this envelope in a log. The harness never returns it. The service keeps stdin
open while the run is active; EOF, any additional input, SIGINT, or SIGTERM
cancels the run. The harness exits after one terminal event. For ordinary CLI
use, prefer `fritz chat`; piping a request and immediately closing stdin is
cancellation, not a way to wait for a response.

Harness stdout emits the same events as the app protocol but without a request
`id`. The service forwards nonterminal events with the original ID and sends
one terminal `result`/`error`. New events are:

| Event | Fields | Meaning |
| --- | --- | --- |
| `activity` | `message` | Model-loop progress |
| `tool_start` | `toolCallId`, `name`, `summary`, `details` | A tool is about to execute; `details` is bounded argument JSON |
| `tool_end` | `toolCallId`, `name`, `success`, `details` | The tool finished; `details` is bounded result JSON |

`toolCallId` is unique within the UI transcript and distinct from provider call
IDs. Failures become native tool results so the model can correct a call or
inspect a failed command. Incomplete provider streams never dispatch tools.
Rig 0.42's `AgentRun` drives every chat, including chats without a folder and
Fritz local models. Fritz supplies provider IO, preserves native reasoning and
tool-result history, and enforces execution limits. Folder actions are registered
in Rig's `ToolSet`; no additional built-in or MCP tools are enabled implicitly.
Calls run sequentially. The run returns when a complete model turn contains
text and no tool calls, or fails on its turn/tool/context/deadline limit.
The final permitted model turn cannot dispatch further tool calls.

Tool definitions: `list_files`, `read_file`, `create_file`, `edit_file`, and
`run_command`. See `src/tools.rs` for typed arguments and runtime validation.
`read_file` displays `N: ` line-number prefixes. These prefixes are metadata,
not file content; `edit_file` expects literal text without those prefixes.
File `path` and process `working_directory` arguments are relative to the
attached folder; `.` identifies its root. Their model-facing schemas describe
this requirement. Absolute paths, `..`, and `.git` are rejected with corrective
feedback. Malformed argument JSON rejects the entire batch before execution;
valid JSON with invalid arguments returns a tool error the model can correct.
Runs permit at most 64 calls and 600 seconds. Provider payloads are capped
at 2 MB, provider streams at 8 MB per turn, and private input lines at 3 MB.
The tools enforce file and output limits documented in the README. Shells
start a new process group; normal completion, timeout, and cancellation kill
that group. Commands deliberately detached into a new process group are not
supported. The command environment is an allowlist without provider keys.
This is local execution with user permissions, not an OS sandbox.

OpenAI output/reasoning items, Anthropic content/signature blocks, Gemini parts
and thought signatures, OpenRouter signed reasoning details, and compatible/Ollama assistant tool calls are retained
in memory between model turns, followed by their provider-native tool results.
The app persists human-readable tool records alongside assistant messages.
After an interruption, these records remain in future model context with an
explicit notice that the workspace must be rechecked. Actions are not rolled
back automatically. Provider-native hidden reasoning is not persisted to the
app transcript.

Protocol references used for the adapters:
[OpenAI function calling](https://developers.openai.com/api/docs/guides/function-calling),
[Anthropic streaming](https://platform.claude.com/docs/en/build-with-claude/streaming),
[Gemini function calling](https://ai.google.dev/gemini-api/docs/function-calling),
[OpenRouter reasoning preservation](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens),
and [Ollama tool calling](https://docs.ollama.com/capabilities/tool-calling).

Local decision connections use provider `ollaya`, model `laya-en`, no endpoint,
and no API key. A saved Ollaya `connectionId` selects the local harness backend;
explicit host requests use `backend: {"kind":"ollaya"}` and omit `apiKey`.
Downloads use the same `progress` shape as `localModels.install`, with byte counts
aggregated across the model artifacts. Listing and evaluation never download files.
The harness requires the model artifacts to be present in the shared Models
directory, uses CPU inference, rejects truncated state, and
returns a resolved `laya-en@<revision>` ID. Score legends preserve JSON criteria,
including objects. All decision requests have a 120-second harness deadline;
closing stdin or sending SIGTERM/SIGINT cancels native loading/inference too.
