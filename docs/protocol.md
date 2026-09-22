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
blocking inference worker. Only one model's weights are cached, with a fresh
context per request. Local usage events include a `truncated` flag when the
2,048-token output limit is reached; context is limited to 8,192 tokens.
