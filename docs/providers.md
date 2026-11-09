# Providers and model selection

[Back to README](../README.md)

In **Settings → Models**, click **+** and choose any LLM or decision provider from
**Provider**.

New Models initially selects the first LLM provider preset that has not been added, or
OpenAI if all LLM presets are already present. Search or use the System1 / Local /
Remote / Frontier / Hosted / Custom filters; System1 shows OpenAI, TypeSafe, and Ollaya
decision models. Enter an API key if needed. The list shows both model categories
together; open a provider from the list to edit it and change its service using the
**Provider** dropdown. A provider and endpoint can be added once; Fritz and Ollaya
connections are unique per local model. Duplicate selections show a warning and cannot
be added. Model catalogs are discovered automatically, and the provider editor can retry
discovery.

The Models table summary and Show Models list put newer chat families and flagship
variants first, with legacy and specialty models later; this is a display heuristic, not
a model-quality evaluation. Click **Show Models** on the Models row to browse and search
the discovered models; recently selected models from that provider appear first.

Click the **Advanced** section header to show or hide optional Gateway URLs, connection
naming, and default/manual model choices. Gateway URL shows the provider’s default
endpoint as its placeholder; leave it blank to use that default. OpenAI-compatible
connections require a Gateway URL in the main section. Hosted presets supply their own
default URLs. TypeSafe also exposes its optional Gateway URL under Advanced.

Supported LLM adapters: OpenAI (Responses), OpenRouter, Anthropic, Google (Gemini),
Ollama, and OpenAI-compatible services. Fireworks, Amazon Bedrock Mantle, and Baseten
have endpoint presets. The generic endpoint expects the OpenAI chat completions
protocol. Ollama uses its native API. Catalogs are discovered live; a manual model ID
also supports services without a catalog endpoint.

## Import and export

Use the **Import and Export** menu beside **+** to import or export providers as cURL.
Command-click to select multiple providers. Import accepts cURL exports and GET checks
to `models`, `api/tags`, or `health` endpoints with standard API key headers; it parses
text without executing shell commands. JSON configurations are not supported.
**Overwrite existing** is checked by default and updates a single matching service while
preserving its identity and saved key when the endpoint is unchanged. Uncheck it to
leave matching services alone. Ambiguous matches require removing duplicates first.
Imports without required keys show **Needs Setup** until a key is added.

Export offers **Without Keys** or **Including API Keys** and generates a GET request to
the provider’s model list, without requiring a model or running inference. cURL comments
preserve the provider, connection name, and selected model for import. Commands read
their options from stdin, and required omitted keys use `YOUR_API_KEY`, which import
treats as missing. Native local model connections without an HTTP endpoint cannot be
exported as cURL. Included keys are readable in the copied command. The default chat
provider preference and downloaded model files are not exported.

## Chat model picker

The shared chat model picker fills at most two compact wrapping rows, prioritizing
common language-model providers. An ellipsis opens Models for the remaining providers;
the Models button also opens provider management. Unconfigured provider filters show a
small open arrow. Select one to open New Provider with that provider selected;
configured providers filter their models, including while discovery is loading or has
failed.

## Model metadata

Supplemental model capabilities, metadata, and prices live in the single
`Sources/Fritz/ModelCatalog.json`. The app seeds from the bundled file and checks the
rel.me catalog on every Models load with HTTP conditional requests. Provider APIs
continue to determine which models your account can access. Models.dev is used only by
the repository's import script, never by the app. The rel.me deployment must adopt
Fritz's exported catalog handler to serve this new representation.

See [chat controls](chat.md#model-selection-and-keyboard-shortcuts), [local
models](local-models.md), and [decision models](decision-models.md).
