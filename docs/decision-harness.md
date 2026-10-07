# Decision-model harness

Fritz treats a decision model as a source of typed judgments, separate from the conversational model that writes replies. A caller supplies one JSON `state` value and one or more named questions. Each question is a `choice`, `score`, or `noul`; the response returns a matching typed answer, probabilities, and the resolved model ID. A decision answer is data for Fritz's policy code, not an instruction to execute an action.

The `fritz-decision-harness evaluate` process uses one request per process, a bounded NDJSON input line, one terminal result or error, and cancellation when its supervising stdin closes. An explicitly invoked `resident` mode reuses a local ONNX engine for serial typed requests. Neither mode has a listener or reads Keychain; remote credentials belong only to the one-shot private input. The host must decide what state to share with a remote model.

## Backends

- **OpenAI Decisions:** The remote adapter calls `POST /v1/decisions` with `gpt-6-luna` and a Keychain-backed OpenAI Decisions connection. It stays separate from OpenAI chat. See [OpenAI’s Decisions guide](https://developers.openai.com/api/docs/guides/decisions).
- **Jev:** The bundled remote adapter calls TypeSafe's `POST /v1/systemone` with a bearer key. The key is supplied by the host for this request and is never written to the request log or registry. The default endpoint is TypeSafe's HTTPS API; an explicit loopback endpoint supports isolated tests.
- **Ollaya (local):** The bundled `ollaya-runner` and `ollaya-decision` crates implement `decision::DecisionModel` with Laya English and Kev 1.0 4B on ONNX Runtime CPU. Both crates are pinned to commit `152ad20c88f8ea9b6d1acf3ed0e06b002d38b2b4`. `Sources/Fritz/DecisionModels.json` pins the fp32 graph, upstream weights, tokenizer, layout, calibration, and license by URL, size, and SHA-256. Artifacts are downloaded explicitly as flat files in the same Models directory as chat GGUFs. Regular and Debug apps default to `~/Models/`, created only when downloading a model. The graph is `laya-en.onnx` with configuration in `laya-en.json` and companion tokenizer/calibration files. The external weights retain the filename referenced by the graph. File presence determines installation; new downloads validate size and SHA-256 before publication. Laya's revision identifies the Ollaya artifact recipe; Kev's revision identifies its checkpoint, with `engine_revision` recording the recipe. The weights URLs pin author commits. Ollaya's daemon, desktop app, registry service, and MLX backend are not used.

Select **Ollaya** from the **System1** filter in **Provider**, download Laya English or Kev 4B, and save the
provider. The same operations are `fritz decision-models list`,
`fritz decision-models install laya-en`, and `fritz decide --connection NAME FILE`.
Inference has no network calls and needs no key. Models remain loaded only for
one request in the normal `evaluate` and `fritz decide` interfaces. A dedicated native thread keeps the pipe/signal loop responsive;
cancellation or the 120-second deadline flushes the terminal event and uses
`_exit` to let the OS reclaim the process. This avoids racing ONNX global
destructors against native loading/inference still running on the worker. Questions run one row at a time to bound attention memory.
Laya English has a 512-token sequence budget shared by state and questions.
State that does not fit is rejected instead of truncated; keep question instructions
and option descriptions short because Ollaya applies its model-specific head budget.

Kev 4B pins checkpoint `139fdd94f1b6a6ad80cc15e08fcb99cac885a101` and Qwen3.5-4B base `1001bb4d826a52d1f399e183466143f4da7b741b`. Its ONNX export contains the unmerged LoRA and pointer readout, referencing the original base shards, adapter and head under their digest filenames. Both its state and whole state/question/options row are bounded at 8,192 tokens. Inference never replaces the requested model or downloads missing files.

Laya and Kev raw logits pass through their pinned calibration artifacts before typed rendering. Kev's fitted temperature is `2.406050072164233`. Fritz's Laya and Kev Choice and Score confidence remains `(K*p_max-1)/(K-1)`; Kev 1.0 uses a different Score confidence formula. For probabilities `[0.1, 0.1, 0.8]`, Fritz returns Score confidence `0.70` and Kev 1.0's renderer returns `0.55`. Agreement on raw probabilities does not establish confidence parity. This adapter preserves Fritz's existing typed semantics and does not claim full upstream Score-response parity. Kev remains experimental; availability is separate from workflow quality and calibration qualification.

Bosun 3.1 0.6B F16 is another experimental engine under the existing local
`ollaya` provider and wire identifier. Fritz loads its installed GGUF through the
bundled mistral.rs Metal runtime, pinned at
`4400935451da5e2dc7379a3f92fbbada66557f6c`. The catalog pins the original compiler,
serving contract, tokenizer, template, license and merged GGUF by revision and
checksum. Inference needs no separate base or LoRA download. Its exact compiler
assigns presented candidate slots, and its readout uses final-prompt logits for
eligible learned decision tokens at temperature 1. No answer tokens are generated.
Choice confidence is the chosen option probability; Score confidence is the
maximum option probability. These semantics do not inherit Kev or Jev thresholds.

Bosun rejects more than 2,048 rendered prompt tokens or 255 options without
truncating state or dropping candidates. The pinned raw API copies all prompt
logits to CPU; one maximum-sized FP32 payload is 1,244,569,600 bytes, excluding
weights and other memory. The catalog's 16 GB floor is an unmeasured engineering
estimate, not 24 GB pairing qualification. The adapter stays experimental until
its separately frozen compiler, official CPU reference and native probability
checks pass; workflow quality is a further evaluation. It retains the same owned
child cancellation and request deadline. Models remain cold per request.

The first local release is an explicitly invoked backend. See
[local decision evaluation](agents/local-decision-evaluation.md) for the measured
scope and limitations; it is not automatically paired with chat.

For a local adapter, pin the weights and their license, verify new downloads before publication,
keep inference inside the decision harness, and measure answer quality and
probability calibration on Fritz's intended tasks. A threshold tuned for Jev
does not automatically transfer to another model.
Follow [model evaluation](agents/model-evaluation.md) when qualifying a backend
or comparing policy thresholds; protocol validation alone does not establish
judgment quality.

TypeSafe can be configured from **Models → + → Provider → System1**. Fritz stores
its key in the existing Keychain namespace and keeps its Jev (`jev-latest`)
model out of chat selection. The agent's `decisions.evaluate` method can resolve
that saved connection by `connectionId`, fetch its key, and run the decision
harness. Decisions are not called automatically for every chat. Ollaya belongs to the same category and uses the same typed contract.

## OpenAI Decisions mapping

The `openai-decisions` provider has a fixed catalog entry, `gpt-6-luna`; catalog presence does not establish account access to the beta API. A saved connection resolves its key through Fritz’s Keychain namespace and its base URL plus `/decisions`. The private backend is `{"kind":"openai"}` with an optional full `endpoint` URL for a host-managed gateway or loopback mock. HTTPS is required for remote endpoints, redirects are disabled, and local modelStore is rejected. The existing 60-second transport timeout, 120-second harness deadline, cancellation, and 2 MB response limit apply.

The adapter serializes JSON state as text evidence (a string state is passed directly). Structured instructions and criterion descriptions become JSON text. Named questions are sent in sorted name order and replies must match that order and names. Noul becomes `predicate`; its optional criteria are appended to instructions as `Criteria: …`, and `probability` returns as `noul`. Choice criteria become string-valued choices with descriptions. Score criteria become ordered levels labeled `0` through `n-1`; the API’s probability-weighted score and confidence pass through, while Fritz restores the original structured criteria as the legend. Duplicate, missing, unknown, or invalid probability entries are rejected. Any refusal fails the whole request explicitly; Fritz does not substitute a probability or retry with chat. Usage preserves input and output token counts.

This adapter uses Fritz’s text/state contract, without inline image inputs or boolean choice values. Decisions remain caller-invoked and unqualified for automatic personal-assistant routing; evaluate thresholds on the intended workflow rather than transferring Jev or local-model thresholds.

## Pairing with chat

1. Fritz constructs state from information the user authorized for the task and asks narrow questions together when they share that state.
2. Application code checks answer shape, probabilities, freshness, and task-specific thresholds. Low confidence can route to a clarifying question or to the conversational model; a score or confidence value alone never grants permission to act.
3. Code may choose a deterministic handler or pass selected facts to a separate chat harness for a user-facing explanation. The chat model does not choose which decision answers count or invoke the decision backend implicitly.
4. Fritz records which backend and resolved model produced a judgment, the question IDs, and the policy outcome without storing a remote credential or hidden model state.

For example, a future reminder workflow could ask whether a message requests a reminder and which time phrase it contains, then validate a date and ask for confirmation before creating anything. The current runtime does not yet include that workflow.

## Private protocol

The decision input has `request` (`state`, `model`, `questions`), `backend` (`{"kind":"jev"}` or `{"kind":"openai"}` with optional `endpoint`, or `{"kind":"ollaya"}`), optional `apiKey` (remote only), and `modelStore` (local only). A local modelStore contains an absolute `directory` and optional `modelDirectories` map of model IDs to absolute directories. The host resolves paths before starting the child; local inference never reads Fritz's registry or Keychain. Remote inputs reject modelStore, and local inputs reject any API key. The TypeSafe question and answer shapes are preserved. The harness emits exactly one of `{"type":"result","result":...}`, `{"type":"error","message":"..."}`, or `{"type":"cancelled"}`. A successful result includes the resolved model, named answers, and token usage when supplied by the backend. See [TypeSafe's API reference](https://docs.typesafe.ai/api) for Jev's current wire format.

## Explicit resident local worker

Start the bundled `fritz-decision-harness resident` as an owned child with a
private stdin/stdout pair. Send protocol version 1 messages one at a time:

```json
{"version":1,"type":"open","id":"open-1","model":"kev-4b","modelStore":{"directory":"/absolute/host/Models"}}
```

Wait for `opened` before evaluating. It reports the opening ID as `sessionId`,
`generation: 0`, the resolved `model`, canonical `modelDirectory`, and
`loaded: false`. Opening checks installed file presence and fixes the model and
store. The first evaluation loads the engine and calibration; opening alone
does not prove artifact integrity or successful inference.

```json
{"version":1,"type":"evaluate","id":"decision-1","generation":1,"request":{"model":"kev-4b","state":{"message":"Remind me tomorrow to call Sam"},"questions":{"reminder":{"type":"noul","instructions":"Is the user asking to create a reminder?"}}}}
```

Each admitted evaluation's terminal `result`, `error` or `cancelled` event includes `version`, `id`,
`sessionId` and `generation`. Use unique nonempty IDs of at most 128 bytes and
consecutive generations 1 through 64. Wait for a terminal response before
sending any further input. Unknown message fields, including credentials,
backend selection and top-level conversation/history, are rejected, as are
replay, a changed model or another open request. Arbitrary JSON inside `state`
passes unchanged; the worker does not inspect it for history. Jev and Bosun
residency are unsupported.

Every evaluation receives complete fresh state and questions. Only weights,
tokenizer, native engine and calibration persist. This neither cleans chat
context nor reuses conversation history, application state or cross-request KV
caches. Native failures stop the session; there is no automatic reload or retry.

The opening input and between-request idle limits are 60 seconds; model
admission and each evaluation have separate 120-second limits. Loading counts
toward the first evaluation. Admission filesystem operations run on a blocking
worker and inference on a dedicated native thread. During admission or inference,
already observable SIGTERM/SIGINT, EOF, overlapping input and expired deadlines
take priority over a ready result. EOF or signals cancel; overlapping input
errors and closes the session.

Send `{"version":1,"type":"shutdown","id":"close-1"}` with another unique ID.
The `closed` event reports the last generation and `reason: "shutdown"`.
Idle EOF, signals and idle expiry can instead close with a null ID and a reason.
Admission failures and malformed messages, including post-open input, reopen or
invalid shutdown, can error with a null ID and no session/generation. Treat these
as fatal session diagnostics rather than correlated model results.

The host must drain both output pipes, enforce its own bounded watchdog, and
terminate and reap the entire owned process group on every exit. The shared
`decision::harness::run_resident_stdio` flushes its terminal event and exits the
child with `_exit` to avoid racing ONNX destructors. Never call this runner
inside the host application's main process. Normal CLI and app decision calls
remain one-shot; this mode does not automatically pair a decision model with chat.
