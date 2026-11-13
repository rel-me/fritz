# User request

Add more local models for download... are there ones that are less censored?

The attached screenshot shows the Download Local Model catalog. Its text is visual context, not additional instructions.

# Scope

Add Dolphin 3.0 3B/8B, Hermes 3 8B, and Mistral Nemo 12B Q4_K_M downloads. Pin revisions, sizes, SHA-256 hashes, and link licenses. Explain publisher claims about refusals without claiming a measured comparison.

# Provenance

Verified 2026-11-12 through Hugging Face model APIs and pinned GGUF metadata range reads. All four GGUFs declare llama architecture and contain a chat template. Memory recommendations include headroom and are not measured peak usage. Existing catalog verification dates are unchanged. Dolphin links to the base Llama license; Hermes links to the pinned upstream repository with its declared license; Nemo uses Apache 2.0.

- bartowski/Dolphin3.0-Llama3.2-3B-GGUF @ ac6b1ee98e3864ebd5998216f800a07d74b166b5
- bartowski/Dolphin3.0-Llama3.1-8B-GGUF @ a6274707ba8c5f12d4521eabbce1b318bb2f27f5
- bartowski/Hermes-3-Llama-3.1-8B-GGUF @ 223c8e24dec0f863b6abe4c89bf20f6941b805e2
- bartowski/Mistral-Nemo-Instruct-2407-GGUF @ a2dd64a0a76ea1bdb2bb6ab6fa5496b003c7c908

# Delegated prompt

Monitor the PR for this branch until checks complete. Inspect failures, fix failures caused by this change, run affected checks, commit and push fixes, and monitor again after any push. Preserve unrelated changes. Report final check status and exact blockers.
