# User request

Fix npm vulnerabilities

# Required workflow

Create a branch and PR; commit and push changes. Monitor the PR in a sub-agent and fix failures; monitor again if the PR changes after a successful run. Record the user request and delegated prompts in this file.

# Implementation and validation

Upgraded the website's pinned Wrangler from 4.148.0 to 4.164.0 and regenerated its lockfile. A clean npm ci, all 11 website tests, npm audit (zero vulnerabilities), and Wrangler deployment dry run passed.

The separate npm project at vendor/llama.cpp/tools/ui belongs to the pinned upstream Git submodule. Its audit reports 41 findings (29 high, 11 moderate, 1 low); this change does not modify that upstream repository or advance the native inference dependency.

# Delegated prompt

Monitor the PR for this branch until its checks finish. Fix failures caused by this change, run affected checks, commit and push any fixes, and monitor again after every push. Preserve unrelated changes. Do not merge. Report check results and exact blockers. Append any follow-up delegated prompts to this file.
