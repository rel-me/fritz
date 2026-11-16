# User request and delegation

The user requested fixing CI and monitoring PR #112 through completion. Delegated prompt: monitor head b048a9a3cd1f107f801f3703ff8d084833dce610; inspect GitHub failed logs, fix attributable failures with narrow verification, commit/push repairs and monitor again after each push. Preserve root changes, no merge or duplicate runs.

# Observed failure and change

Run 43837678217 passed every snapshot and all Swift tests, then failed `OwnedGroupLifetime.test_exit_zero_parent_gets_full_eof_grace_for_its_owned_descendant`: the test-only `ensure_group_gone` cleanup helper raised PermissionError from `os.killpg(pid, 0)` before finishing its existing two-second observation window. The owning transport already documents Darwin's transient permission failures while a group is reaped and treats them as unknown.

Preserve the same bounded test cleanup window, retry unobservable group checks, fail explicitly if the group remains unobservable, and never send a signal to an unobservable group. Only ProcessLookupError proves disappearance. The frozen historical transport, current transport, production runtime, and immutable provenance remain unchanged. Reuse the existing seven-test owning suite rather than adding duplicate helper tests.

# Verification

`mise exec -- python3 scripts/build-cache.py python3 tests/test_bosun_transport.py` passed all seven existing tests in 5.903 seconds. `git diff --check` passed. No production code, snapshot references, tolerances, or test skips changed.
