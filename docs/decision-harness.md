# Decision-model harness

Fritz treats a decision model as a source of typed judgments, separate from the conversational model that writes replies. A caller supplies one JSON `state` value and one or more named questions. Each question is a `choice`, `score`, or `noul`; the response returns a matching typed answer, probabilities, and the resolved model ID. A decision answer is data for Fritz's policy code, not an instruction to execute an action.

The `fritz-decision-harness` process uses the same private-pipe lifecycle as chat: one request per process, a bounded NDJSON input line, one terminal result or error, and cancellation when its supervising stdin closes. It has no listener, does not read Keychain, and receives a remote credential only through its private input. The host must decide what state to share with a remote model.

## Backends

- **Jev:** The bundled remote adapter calls TypeSafe's `POST /v1/systemone` with a bearer key. The key is supplied by the host for this request and is never written to the request log or registry. The default endpoint is TypeSafe's HTTPS API; an explicit loopback endpoint supports isolated tests.
- **Ollaya (local):** The bundled `ollaya-runner` and `ollaya-decision` crates implement `decision::DecisionModel` with Laya English and Kev 1.0 4B on ONNX Runtime CPU. Both crates are pinned to commit `152ad20c88f8ea9b6d1acf3ed0e06b002d38b2b4`. `Sources/Fritz/DecisionModels.json` pins the fp32 graph, upstream weights, tokenizer, layout, calibration, and license by URL, size, and SHA-256. Artifacts are downloaded explicitly as flat files in the same Models directory as chat GGUFs. Regular and Debug apps default to `~/Models/`, created only when downloading a model. The graph is `laya-en.onnx` with configuration in `laya-en.json` and companion tokenizer/calibration files. The external weights retain the filename referenced by the graph. File presence determines installation; new downloads validate size and SHA-256 before publication. Laya's revision identifies the Ollaya artifact recipe; Kev's revision identifies its checkpoint, with `engine_revision` recording the recipe. The weights URLs pin author commits. Ollaya's daemon, desktop app, registry service, and MLX backend are not used.

Select **Ollaya** from the **System1** filter in **Provider**, download Laya English or Kev 4B, and save the
provider. The same operations are `fritz decision-models list`,
`fritz decision-models install laya-en`, and `fritz decide --connection NAME FILE`.
Inference has no network calls and needs no key. Models remain loaded only for
one request. A dedicated native thread keeps the pipe/signal loop responsive;
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

## Pairing with chat

1. Fritz constructs state from information the user authorized for the task and asks narrow questions together when they share that state.
2. Application code checks answer shape, probabilities, freshness, and task-specific thresholds. Low confidence can route to a clarifying question or to the conversational model; a score or confidence value alone never grants permission to act.
3. Code may choose a deterministic handler or pass selected facts to a separate chat harness for a user-facing explanation. The chat model does not choose which decision answers count or invoke the decision backend implicitly.
4. Fritz records which backend and resolved model produced a judgment, the question IDs, and the policy outcome without storing a remote credential or hidden model state.

For example, a future reminder workflow could ask whether a message requests a reminder and which time phrase it contains, then validate a date and ask for confirmation before creating anything. The current runtime does not yet include that workflow.

## Private protocol

The decision input has `request` (`state`, `model`, `questions`), `backend` (`{"kind":"jev"}` with optional `endpoint`, or `{"kind":"ollaya"}`), optional `apiKey` (Jev only), and `modelStore` (local only). A local modelStore contains an absolute `directory` and optional `modelDirectories` map of model IDs to absolute directories. The host resolves paths before starting the child; local inference never reads Fritz's registry or Keychain. Remote inputs reject modelStore, and local inputs reject any API key. The TypeSafe question and answer shapes are preserved. The harness emits exactly one of `{"type":"result","result":...}`, `{"type":"error","message":"..."}`, or `{"type":"cancelled"}`. A successful result includes the resolved model, named answers, and token usage when supplied by the backend. See [TypeSafe's API reference](https://docs.typesafe.ai/api) for Jev's current wire format.
