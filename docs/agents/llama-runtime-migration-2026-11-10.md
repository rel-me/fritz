# llama.cpp migration and final package size

Measured November 10, 2026 on an Apple M2 Pro with 32 GiB RAM and macOS 26.7.1.

Fritz now uses llama.cpp for catalog GGUF chat models and Bosun. The final
distribution-configuration app measures **65.51 MiB** and its installer DMG
measures **28.03 MiB**. The runtime is statically linked; no inference dylibs
or separate model service were added.

## Package sizes

| Artifact | Shared mistral.rs build | llama.cpp build | Reduction |
| --- | ---: | ---: | ---: |
| App file contents | 152.96 MiB | 65.51 MiB | 57.2% |
| Shared Rust runtime | 131.32 MiB | 43.86 MiB | 66.6% |
| Installer DMG | 60.13 MiB | 28.03 MiB | 53.4% |

Both comparison builds use the existing distribution architecture settings:
the Swift app contains arm64 and x86_64 slices, and the bundled Rust runtime is
arm64. Sizes sum regular files once, excluding symlink aliases. Model weights
are downloaded separately and are excluded from both apps. The DMGs use the
existing Finder layout, HFS+ and UDZO compression. Both measurements use
local ad-hoc signing; this task did not publish a release.

The original published v0.1.7 DMG was 151.82 MiB before executable
deduplication and symbol stripping. The final 28.03 MiB image is about
81.5% smaller than that original installer.

## Runtime changes

llama.cpp is pinned by the `vendor/llama.cpp` submodule at
`7c2653acc749258dc62067da62d07024d971ccd2`. The CMake build enables CPU, Metal,
embedded shader source and common Jinja/tool support. Servers, command-line
tools, examples, subprocess support, OpenSSL, BLAS and OpenMP are disabled.
The former mistral.rs dependency and its Metal compiler-cache adapter are removed.

The existing per-chat and decision harness processes and private pipes remain.
Chat uses the GGUF Jinja template, tool grammar and response parser. Fritz
validates complete calls before invoking its existing tools and retains paired
tool results in subsequent turns. Length-limited responses cannot execute tools.
Cancellation reaches native loading, prompt batches and decoding through a
shared atomic flag. Handles serialize context access and retain ownership until
their native workers finish.

Bosun retains its artifact verification, prompt compiler, decision-token IDs,
stable-slot ordering, probability normalization and typed answers. Its native
readout copies only eligible final-position logits without generating answer
tokens. Other local ONNX engines and remote decision backends retain their
existing implementations.

## Verification

`make test` and `make check` passed. The complete app was built with:

```sh
FRITZ_DISTRIBUTION=1 CONFIGURATION=release make build
```

The staged single-executable bundle passed the CLI/agent, coding and decision
protocol suites. Real model checks used isolated data and already downloaded,
SHA-256-verified weights. No personal provider credentials were used.

Seven retained catalog GGUFs streamed the exact response `Café ready 😀`:

- Qwen2.5 1.5B Instruct Q4_K_M
- Qwen3 0.6B, 1.7B and 4B Q4_K_M
- Qwen3.5 0.8B, 2B and 4B Q4_K_M

Qwen3.5 4B completed a real read → edit → read/verify sequence, changing the
synthetic file from `before` to `after` and receiving tool results across four
model turns. A separate native run invoked `run_command`; EOF cancelled its
owned shell/sleep process group and the harness exited cleanly.

Additional real-runtime checks passed for streaming cancellation, health after
cancellation, EOF during model loading and generation, JSON API output, reuse of
a retained API model after a disconnected streaming request, one-token length
limits and Bosun decision-harness cancellation.

The five frozen Bosun compiler fixtures retained their selected candidate
against the pinned mistral.rs baseline. Input token counts matched and output
usage remained zero. Maximum absolute probability differences were:

| Frozen case | Maximum probability difference |
| --- | ---: |
| structured-choice-unicode-floats | 0.000249333 |
| mixed-descriptions-choice | 0.000056844 |
| structured-score | 0.000588610 |
| noul-default-criteria | 0.000987306 |
| noul-structured-criteria | 0.000002738 |

These checks establish runtime agreement on this cohort. They do not qualify
answer quality, probability calibration or automatic decision-based workflows.
The earlier [14-model performance report](runtime-benchmark-2026-11-10.md)
records the broader standalone benchmark and its hardware/cache limitations.
The larger catalog models were not rerun through the final application adapter.

## Artifact provenance

- Application source commit: `f2174395dd32b1fffa14eb52afac54512b50687e`
- App regular-file bytes: `68692136`
- Shared runtime bytes: `45995392`
- Shared runtime SHA-256: `0d6b6b245d9227a33be83d75e30effa7a1172176d93870a67df7795ce5b87f0f`
- DMG bytes: `29390599`
- DMG SHA-256: `f0bc8bb0ef39e578a329184e75b84ee597cdab100af5604d260807c0ffaf9087`

`hdiutil verify` and deep strict signature verification passed. The read-only
mounted image retained both relative harness aliases; each dispatched its
expected CLI, and the mounted runtime SHA-256 matched the tested staged binary.
Its dynamic dependencies are macOS system libraries/frameworks.

Local artifacts and receipts remain under ignored `dist/llama-migration/`:
`report.json` records driver sources, hashes, raw harness events, model hashes,
baseline logits, package sizes and log tails. The measurement DMG is
`dist/Fritz-llama-size-check.dmg`; the staged app is `dist/Fritz.app`.
Bulk experimental receipts are local artifacts rather than checked-in data.
The normal opt-in streaming/cancellation check remains `tests/local_inference.py`.
