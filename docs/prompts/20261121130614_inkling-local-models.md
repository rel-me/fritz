# User request

Add inkling support for local downloadable models

# Scope

Add Thinking Machines Lab's Inkling 2 Mini to the Fritz local download catalog for text chat. Use the GGUF published by ggml-org and update the upstream llama.cpp pin to support the looped architecture. Hugging Face repository metadata and the pinned download headers agree on the byte count and SHA-256. The memory recommendation is an estimate. Scale the transfer deadline with file size after the real download showed that a healthy transfer can exceed the fixed 30-minute limit.

# Delegated prompt

Monitor the ready PR until all checks finish. Investigate failures, fix regressions introduced by the change, run affected checks, commit and push fixes, and monitor the resulting head until it passes. Preserve unrelated changes. Log follow-up prompts in this file and report the final check status or blockers.
