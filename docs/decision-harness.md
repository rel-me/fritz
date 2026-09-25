# Decision-model harness

Fritz treats a decision model as a source of typed judgments, separate from the conversational model that writes replies. A caller supplies one JSON `state` value and one or more named questions. Each question is a `choice`, `score`, or `noul`; the response returns a matching typed answer, probabilities, and the resolved model ID. A decision answer is data for Fritz's policy code, not an instruction to execute an action.

The `fritz-decision-harness` process uses the same private-pipe lifecycle as chat: one request per process, a bounded NDJSON input line, one terminal result or error, and cancellation when its supervising stdin closes. It has no listener, does not read Keychain, and receives a remote credential only through its private input. The host must decide what state to share with a remote model.

## Backends

- **Jev:** The bundled remote adapter calls TypeSafe's `POST /v1/systemone` with a bearer key. The key is supplied by the host for this request and is never written to the request log or registry. The default endpoint is TypeSafe's HTTPS API; an explicit loopback endpoint supports isolated tests.
- **Local:** `decision::DecisionModel` is the backend contract for a native local model. It consumes the same validated `DecisionRequest` and returns the same validated `DecisionResponse`. No local decision-model weights or adapter are bundled yet. Fritz's Qwen GGUFs are conversational models and should not be labeled as calibrated decision models. Choose and evaluate a local decision model before exposing one in the app.

For a local adapter, pin the weights and their license, verify them before loading,
keep inference inside the decision harness, and measure answer quality and
probability calibration on Fritz's intended tasks. A threshold tuned for Jev
does not automatically transfer to another model.

Jev can be configured from **Model Providers → + → Decision Models**. Fritz stores
its key in the existing Keychain namespace and keeps its fixed `jev-latest`
model out of chat selection. The agent's `decisions.evaluate` method can resolve
that saved connection by `connectionId`, fetch its key, and run the decision
harness. Decisions are not called automatically for every chat. A future local
decision model belongs in the same category and must implement the typed backend
contract before it is exposed in settings.

## Pairing with chat

1. Fritz constructs state from information the user authorized for the task and asks narrow questions together when they share that state.
2. Application code checks answer shape, probabilities, freshness, and task-specific thresholds. Low confidence can route to a clarifying question or to the conversational model; a score or confidence value alone never grants permission to act.
3. Code may choose a deterministic handler or pass selected facts to a separate chat harness for a user-facing explanation. The chat model does not choose which decision answers count or invoke the decision backend implicitly.
4. Fritz records which backend and resolved model produced a judgment, the question IDs, and the policy outcome without storing a remote credential or hidden model state.

For example, a future reminder workflow could ask whether a message requests a reminder and which time phrase it contains, then validate a date and ask for confirmation before creating anything. The current runtime does not yet include that workflow.

## Private protocol

The decision input has `request` (`state`, `model`, `questions`), `backend` (`{"kind":"jev"}` with optional `endpoint`), and `apiKey`. The TypeSafe question and answer shapes are preserved. The harness emits exactly one of `{"type":"result","result":...}`, `{"type":"error","message":"..."}`, or `{"type":"cancelled"}`. A successful result includes the resolved model, named answers, and token usage when supplied by the backend. See [TypeSafe's API reference](https://docs.typesafe.ai/api) for Jev's current wire format.
