# Local models

[Back to README](../README.md)

## Download and install

Click the download icon at the top of **Settings → Models**, or choose **New Local
Model** from the **+** or **File** menu, to download a Fritz model from a selectable
list with Name, Type, Size / Status, and Hardware Requirements columns. Use the type
(LLM or Decision) and model-family capsules to combine filters; click a selected capsule
to remove it, or All to reset. The downloadable catalog contains LLMs and experimental
Laya, Kev and Bosun decision models; Jev remains a remote Decision Model. In New Models
or Edit Models, selecting an uninstalled Fritz or Ollaya model shows **Download**, which
installs that model directly with progress and cancellation. Installed models have no
Download button. Where Download appears, **Download to** shows its folder; **Choose…**
selects a different folder for that model. Fritz remembers the folder after installation
and uses it for discovery and loading across launches. Other models keep their own
locations; choosing a folder does not move previously downloaded files. The download
catalog shows the selected model’s license, download progress, and installation status.
Cancel stops the download; Retry starts a fresh attempt. Once the model is installed,
add or edit a **Fritz** provider in **Settings → Models** and select it. Installed
models then become available in the chat model picker. Removing a provider leaves
downloaded weights available for reuse.

## Storage and runtime

Downloads are pinned to repository revisions, file sizes, and SHA-256 hashes. Models run
inside the per-chat Rust harness using mistral.rs 0.9.4 and Metal, without Ollama or a
local HTTP service. No API key is needed. Listing models or sending a chat never starts
a download. By default, weights live under `~/Models/` in both regular and Debug apps.
Fritz creates that folder only when you first download a model. Debug provider and
conversation databases remain separate. Fritz reports a storage error if it cannot
create or write the selected folder. `FRITZ_MODELS_DIR` overrides the default model
folder for tests or CLI use. A model's saved download folder takes precedence over that
default. Folder choices are stored in the profile's `model_locations.sqlite` database.
Chat GGUFs and decision artifacts are flat files in their selected folder. A model is
installed when its required files are present, regardless of size, checksum, or optional
metadata. Decision configuration uses the matching model filename with a `.json`
extension (for example, `laya-en.onnx` and `laya-en.json`). New downloads still validate
size and SHA-256 before atomic publication. Older model directories are not read or
migrated. The provider editor shows the installed model file's path and **Open in
Finder** reveals it. Download and local API actions sit beside their status information.
The native runtime's licenses ship in the app; each model's license is linked in the
download sheet. Memory recommendations are estimates. Local chat supports an 8,192-token
context and up to 2,048 output tokens per model turn.

In a folder-attached thread, a downloaded Fritz model can use the current folder actions
if its GGUF chat template and checkpoint support structured tool calls. The same action
and turn limits apply as for remote providers. In a conversation without a folder, local
models answer without actions.

## Run a local model API

Fritz starts one loopback-only local API when the app opens, including when no models
are installed. Its address and process ID are in **Settings → Service**. Open **Settings
→ Models** and use **New Models** or **Edit Models** for a Fritz model. **Download**,
**Start**/**Stop**, **Start on**, the installed path, and **Open in Finder** appear
together with the model's load status and errors. Start loads and retains that model's
weights in the shared API; Stop unloads those weights while leaving the API available.
**First use** is the default: the model loads when an API request needs it. **App
start** preloads saved Fritz connections when the app launches. Startup choices are
saved per model in the workspace database; Cancel leaves the choice unchanged. Manual
Start works before saving a new connection.

Starting another model compares the combined catalog RAM recommendations against total
RAM and the new model's recommendation against available RAM (free, inactive, and
speculative pages, with 2 GB reserved). This check also applies to first-use API
requests. A memory warning offers Start Anyway or Cancel when the estimated budget is
tight or available RAM cannot be measured. Fritz unloads all API models and stops its
listener when it quits. Changing or deleting a connection unloads its previous API
model. Each chat keeps its separate harness, so API preloading does not warm chat
harnesses. Decision models retain their request-owned decision harnesses.

For command-line use, `fritz local-models serve` listens on `127.0.0.1:11435` until
interrupted. Pass `--port` to choose another port or `--model MODEL_ID` to expose only
one installed model. The API supports `GET /api/tags`, `POST /api/chat`, and `POST
/api/generate`. Chat and generate accept text, `stream: false` for one JSON response, or
the default incremental NDJSON stream. `format: "json"` and `options.num_ctx` /
`num_predict` are supported up to 8,192 context tokens; temperature is fixed at zero.
Raw prompts, tool calls, and images are unsupported by this optional API. The listener
binds only to this Mac's loopback interface. CLI listeners start when requested and
retain one model between requests.
