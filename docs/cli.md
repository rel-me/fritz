# Command-line interface

[Back to README](../README.md)

```sh
make install-cli  # symlink the bundled CLI into ~/.local/bin
fritz --help
fritz local-models list
fritz local-models install qwen3-0.6b-q4_k_m
fritz local-models serve --port 11435
fritz add-provider --name Fritz --provider fritz --model qwen3-0.6b-q4_k_m
fritz chat "Help me plan a quiet weekend" --connection Fritz
fritz providers
fritz add-provider --name Ollama --provider ollama --model llama3.2 --default
fritz models
fritz chat "Make a packing list for a three-day trip" --model llama3.2
fritz chat --connection Ollama --model llama3.2 < prompt.txt
fritz chat "Summarize the notes in this folder" --project /path/to/folder
```

Use **Settings → General → Command Line** to install a symlink to the CLI from
`/Applications/Fritz.app` in a writable folder already in PATH. `make install-cli`
remains available for a checkout-local CLI. Use `--api-key-stdin` with `add-provider` to
read a key from standard input. Keys are never command-line arguments. `fritz
default-provider NAME` changes the default, and `fritz remove-provider NAME` removes the
connection and its saved key. The CLI shares the app’s provider settings and does not
modify the app’s transcript. The current `--project` option attaches a folder and
enables its actions when the model supports native function calling. Assistant text goes
to stdout and action summaries to stderr.

See [the local model API](local-models.md#run-a-local-model-api) and [decision CLI
examples](decision-models.md).
