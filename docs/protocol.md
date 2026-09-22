# App / agent protocol

The app launches the bundled `fritz --agent`. Each stdin line is a JSON request with a unique `id`, `method`, and `params`. Each stdout line is an event carrying the same request `id`. No network listener is opened. The process exits when stdin closes.

| Method | Parameters | Result |
| --- | --- | --- |
| `health` | `{}` | Agent name and version |
| `providers.list` | `{}` | Registry |
| `providers.save` | `connection`, optional `apiKey`, `makeDefault` | Updated registry |
| `providers.remove` | `id` | Updated registry |
| `providers.default` | `id` | Updated registry |
| `models.list` | `connectionId`, or draft `connection` and optional `apiKey` | `models` array |
| `localModels.list` | Optional `modelId` | Pinned catalog entries with `id`, `name`, `size`, verified `installed` status |
| `localModels.install` | `modelId` | Download progress, then `modelId` and `installed: true` |
| `chat` | `connectionId`, `model`, `messages`, optional `effort`, `speed` | Stream, then empty result |
| `cancel` | `requestId` | Cancels request and returns empty result |

A connection contains `id` (UUID), `name`, `provider`, `baseUrl` (optional), and `modelId`. A chat message contains `role` (`user` or `assistant`) and `content`.

Events are `delta` with `text`, `usage` with provider usage metadata, `result` with `result`, `error` with `message`, or `cancelled`. `result`, `error`, and `cancelled` terminate the corresponding request. Registry writes run in arrival order; discovery and chat run asynchronously. The protocol never returns a saved API key. Credentials are passed only over the private input pipe.

Local installs also emit `progress` with `status` (`checking`, `downloading`,
`ready`), `downloaded`, and `total` byte counts. `ready` precedes the terminal
result; it is not itself a completed request. `cancel` aborts a download and
removes its partial file. Retry starts a fresh download. A killed process may
leave a bounded partial file; the next explicit install replaces it. Only files
with the catalog's exact size and SHA-256 are atomically published and loaded.

The `fritz` provider has no endpoint or API key. `models.list` returns its
verified installed models. Listing, saving a connection, and chatting never
implicitly download weights. Local chat streams `delta` and `usage` events
through the same pipes as remote providers; cancellation also signals the
blocking inference worker. Each request loads weights in its own harness
process, with a fresh context. The harness releases Metal resources before
exiting. Local usage events include a `truncated` flag when the 2,048-token
output limit is reached; context is limited to 8,192 tokens.

Fritz local models support `mode: "chat"`; Code requests return a clear error
without dispatching tools. Remote providers retain the native tool loop below.

## Harness and coding runs (protocol version 2)

`chat` additionally accepts `mode` (`chat`, default, or `code`), `projectPath`
(an absolute existing directory, required for Code), and `maxTurns` (1–40,
default 24). The app sends the directory belonging to the request's thread,
not whichever project happens to be selected when a response arrives. The
CLI resolves `--project` to an absolute path and enables Code mode.

Both modes run in a bundled sibling executable, `fritz-harness chat`. The
service resolves the saved provider and key, then writes exactly one NDJSON
line to its private stdin:

```json
{"request":{"connectionId":"UUID","model":"model-id","messages":[{"role":"user","content":"Fix the test"}],"mode":"code","projectPath":"/path/to/project","maxTurns":24},"connection":{"id":"UUID","name":"Example","provider":"openai-compatible","baseUrl":"http://localhost:8000/v1","modelId":"model-id"},"apiKey":null}
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
Calls run sequentially. The loop returns when a complete model turn contains
text and no tool calls, or fails on its turn/tool/context/deadline limit.
The final permitted model turn cannot dispatch further tool calls.

Tool definitions: `list_files`, `read_file`, `create_file`, `edit_file`, and
`run_command`. See `src/tools.rs` for typed arguments and runtime validation.
Code runs permit at most 64 calls and 600 seconds. Provider payloads are capped
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
