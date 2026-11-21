# User request

Add inkling support for local downloadable models

# Scope

Add Thinking Machines Lab's Inkling 2 Mini to the Fritz local download catalog for text chat. Use the GGUF published by ggml-org and update the upstream llama.cpp pin to support the looped architecture. Hugging Face repository metadata and the pinned download headers agree on the byte count and SHA-256. The memory recommendation is an estimate. Scale the transfer deadline with file size after the real download showed that a healthy transfer can exceed the fixed 30-minute limit.

# Delegated prompt

Monitor the ready PR until all checks finish. Investigate failures, fix regressions introduced by the change, run affected checks, commit and push fixes, and monitor the resulting head until it passes. Preserve unrelated changes. Log follow-up prompts in this file and report the final check status or blockers.

## Real-weight follow-up

The full GGUF passed Fritz's installer verification. On a 24 GB Mac, Metal reported insufficient memory with all expert weights in its working set. Keep six prelude layers' expert weights in CPU memory when the available Metal working set is below 20 GiB. Retest 8,192-token chat, bundled cancellation and teardown, and the shared Bosun runtime.

# Delegated follow-up prompt

Monitor the new head of PR #140 after the Metal memory fix. Investigate failures, fix regressions introduced by this PR, run affected checks, commit and push fixes, and monitor the resulting head until it passes. Coordinate with root before modifying the shared checkout or building. Log any follow-up prompts here and report the final CI status or blockers.

## Real-weight verification

The staged bundle completed streaming, cancellation and shutdown with the checksum-verified Inkling weights on a 24 GB Mac. The local API returned the expected reply at an 8,192-token context and reported IQ4_NL. Five frozen Bosun requests matched the previous staged runtime for selected answers, probabilities within 0.002 and token usage.
