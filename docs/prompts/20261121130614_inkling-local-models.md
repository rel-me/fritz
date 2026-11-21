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

## User follow-up

Can you include a score column... which is a score of how good it is.... I know there are a million benchmarks but can we find a good independent one that isn't benchmaxed for local models and allow filtering and sorting based on that... also create a filter for (Runnable on machine, to hide all the ones that won't run on the current machine.)

## Score and hardware filters

Use the same published version of Artificial Analysis Intelligence Index v5.0.1 for both models with matching results. Record Inkling 2 Mini and Qwen3.8 27B in non-reasoning mode as published model scores. Treat all other entries, including decision models and custom fine-tunes, as unscored. The hardware filter combines recommended RAM with Metal availability where the engine requires Metal.

## Delegated score and hardware follow-up prompt

Monitor the updated head of PR #140 after the score and runnable filters. Investigate failures, fix regressions introduced by the change, run affected checks, commit and push fixes, and monitor the resulting head until it passes. Coordinate before changing the shared checkout. Log any follow-up prompts here and report the final CI status or blockers.

## Score and hardware verification

On a 24 GB Mac, the staged Local Models table sorted in both directions with unscored entries last. The runnable filter hid the 32 GB and 48 GB rows. Combining it with the 20-point minimum left Inkling 2 Mini and opened its setup sheet. The focused filter tests and all 21 shared UI snapshot tests passed.
