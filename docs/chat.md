# Using chat

[Back to README](../README.md)

Use **+ → New Project** to name a project and create its first thread. Fritz creates its
folder at `~/Documents/Fritz/{ProjectName}`, replacing spaces and invalid path
characters with hyphens. You can also choose an existing folder. The current app uses
“Project” for a folder group; this is a temporary part of its navigation. Use **New
Chat** from the + or File menu, or press ⌘N, for another conversation. Threads retain
separate transcripts, drafts, and model settings. Their titles come from the first
message; project and thread context menus also offer Rename.

Chat uses REL’s native conversation layout: a floating composer, compact live tool
activity, and a “Worked for…” summary above each completed answer. Expand the summary to
review all tool calls, then click a call to inspect its arguments and result.
Interrupted responses retain their work with an interrupted status. Older tool records
without timing show “Work details.” Scroll up to read without being pulled down by
incoming text; **Jump** returns to the latest response.

The **+** and **File** menus also offer **New Model** to add a connection and **New
Local Model** to open the download chooser in Settings.

## Model selection and keyboard shortcuts

The composer includes model search, provider filtering, recent selections, and
reasoning/speed options for recognized OpenAI models. Provider sections show up to five
recommended models, ordered by current model family and tier rather than alphabetically.
Selecting a provider shows its full catalog without a result limit; OpenAI chat choices
exclude known specialty and legacy completion models. This ordering is a display
heuristic, not a measured popularity or quality ranking.

Its text-only model selector shows friendly model names, the reasoning level, and any
nonstandard speed (Fast or Flex) beside the model name. New chats default to Medium
reasoning and Standard speed. None reasoning is offered only for models with confirmed
support.

Reasoning and speed choices come from the bundled `Sources/Fritz/ModelCatalog.json`
catalog shared by Swift and Rust. The catalog declares lifecycle status and supported
defaults per model. Deprecated models remain selectable but are omitted from
recommendations; retired models are unavailable for chat. Unknown model IDs remain
selectable without extra controls until their capabilities are reviewed and added.

Provider filters fill at most two rows across the available width, with OpenAI,
Anthropic, Google, Ollama, and OpenRouter first. An ellipsis opens Models for providers
that do not fit; the Models button also opens provider management. The selected model’s
provider appears first in the model sections; search still includes all configured
providers. Recent stays above the provider sections and shows up to five available
models, excluding the current selection; Fritz remembers the last eight distinct
selections.

The message field receives focus when opening or switching threads, without a focus
border. Return sends; Shift-Return inserts a newline. Escape stops generation. ⌘N
creates a chat, ⇧⌘N opens New Project, and ⌘, opens Settings. The toolbar opens its
Models page directly. Projects and the selected thread are restored on the next launch.
Switching threads keeps an in-progress response attached to its original thread.

## Activity and usage

Each completed or stopped response displays total tokens, cached input tokens, and USD
cost. When all calls report cost, Fritz uses it; otherwise standard-tier calls use
prices in the shared model catalog, accounting for cache and context tiers. Missing
usage or pricing is shown as unavailable. Earlier summaries remain attached to their
responses after another request or a model change.

## Right panel

The toolbar toggles a blank native inspector on the right, with a resizable divider.
Conversations stay in the main chat area and are selected from the project sidebar.
There is no bottom panel.
