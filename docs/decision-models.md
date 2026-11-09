# Using decision models

[Back to README](../README.md)

## OpenAI Decisions

Under **Settings → Models**, click **+** and choose **OpenAI Decisions** (also available
under **System1**). Add an OpenAI API key to use **GPT-6 Luna** (`gpt-6-luna`) through
the beta Decisions API. Fritz stores the key in Keychain. This connection is separate
from OpenAI chat and cannot become the default chat provider. `decisions.evaluate` and
`fritz decide --connection <name-or-id>` use the existing typed state/questions
contract: Noul maps to a predicate probability, Choice to named options, and Score to
ordered levels. A refused question fails the request explicitly. Chat does not invoke
decisions automatically. Fritz supplies JSON state as text evidence; this adapter does
not accept image attachments. See the [decision-harness guide](decision-harness.md) for
mappings and limits.

## TypeSafe and local decisions

Under **Settings → Models**, click **+**, filter **Provider** by **System1**, and add
**TypeSafe** with a TypeSafe API key. **Jev** (`jev-latest`) is its decision model.
Fritz stores the key in Keychain and shows TypeSafe alongside LLM providers; Jev never
appears in the chat model picker or becomes the default chat provider. Its separate
private-pipe harness accepts Choice, Score, and Noul questions and returns validated
answers with probabilities. The agent exposes this runtime through `decisions.evaluate`;
chat does not invoke it automatically.

## Experimental local models

For offline decisions, choose **Ollaya**, download **Laya English (Experimental)**
(about 850 MB) or **Kev 1.0 4B (Experimental)** (9.49 GB, 32 GB RAM recommended), and
add the provider. Fritz bundles the Ollaya Rust runtime and runs Laya and Kev on CPU
inside its decision harness; no Ollaya installation or server is needed. The same local
provider also includes **Bosun 3.1 0.6B F16 (Experimental)**, a 1.21 GB download using
Fritz's bundled mistral.rs Metal runtime. Bosun returns learned decision-slot
probabilities with a 2,048-token rendered-prompt limit; it does not generate chat
replies. Its catalog RAM floor is provisional, and workflow quality and 24 GB pairing
remain unqualified. Weights download only when explicitly requested. File presence
determines installation; new downloads are checked before publication. Local decisions
are separate from chat, with a 120-second request limit and explicit errors for state
exceeding the model context.

## CLI

The CLI uses the same provider and harness:

```sh
fritz decision-models list
fritz decision-models install laya-en
fritz add-provider --name 'Local decisions' --provider ollaya --model laya-en
fritz decide --connection 'Local decisions' request.json
```

`request.json` contains `model`, `state`, and typed `questions`, for example:

```json
{"model":"laya-en","state":{"message":"Remind me tomorrow to call Sam"},"questions":{"reminder":{"type":"noul","instructions":"Is the user asking to create a reminder?"}}}
```

Use `-` (the default filename) to read JSON from stdin. The model is loaded for each
request; expect seconds of cold-start latency. The initial reminder-routing quality gate
did **not** pass; use this experimental backend for explicit evaluation, not automatic
reminder actions. See the [evaluation results](agents/local-decision-evaluation.md)
before designing a policy around its probabilities. The [local model
comparison](local-browser-pairing.md) records frozen selection measurements and their
limits. See [decision-harness architecture](decision-harness.md) and the [personal
assistant plan](personal-assistant-plan.md).

## Resident worker

Hosts can explicitly start the bundled `fritz-decision-harness resident` for serial
Laya/Kev decisions using a versioned private pipe. It reuses weights with fresh request
state, has bounded lifetime and requires host-owned process-group cleanup. It does not
change `fritz decide`, chat, or app decision calls. Bosun and Jev residency are
unsupported. See [messages and
lifecycle](decision-harness.md#explicit-resident-local-worker).

To install the compact experimental engine explicitly, use `fritz decision-models
install bosun-v3.1-0.6b-f16`, then add an Ollaya connection with that model ID. It
remains separate from the default chat provider.
