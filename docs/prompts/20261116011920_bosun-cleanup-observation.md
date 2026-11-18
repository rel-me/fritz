# User request and delegation

The user requested fixing CI and monitoring PR #112 through completion. Delegated prompt: monitor head b048a9a3cd1f107f801f3703ff8d084833dce610; inspect GitHub failed logs, fix attributable failures with narrow verification, commit/push repairs and monitor again after each push. Preserve root changes, no merge or duplicate runs.

# Observed failure and change

Run 43837678217 passed every snapshot and all Swift tests, then failed `OwnedGroupLifetime.test_exit_zero_parent_gets_full_eof_grace_for_its_owned_descendant`: the test-only `ensure_group_gone` cleanup helper raised PermissionError from `os.killpg(pid, 0)` before finishing its existing two-second observation window. The owning transport already documents Darwin's transient permission failures while a group is reaped and treats them as unknown.

Preserve the same bounded test cleanup window, retry unobservable group checks, fail explicitly if the group remains unobservable, and never send a signal to an unobservable group. Only ProcessLookupError proves disappearance. The frozen historical transport, current transport, production runtime, and immutable provenance remain unchanged. Reuse the existing seven-test owning suite rather than adding duplicate helper tests.

# Verification

`mise exec -- python3 scripts/build-cache.py python3 tests/test_bosun_transport.py` passed all seven existing tests in 5.903 seconds. `git diff --check` passed. No production code, snapshot references, tolerances, or test skips changed.

# Follow-up CI build failure

The fresh run 43838982484 passed tests, including snapshots and the owned-process cleanup suite, then failed in the Chromium CMake compiler probe. `/usr/bin/cc` from selected Xcode 26.6 linked against the independently upgraded CLT macOS 27.2 SDK, rejecting the `arm64e.x1` architecture. Apply the same explicit SDK contract already used for the native Rust build to the owning Chromium build script: honor nonempty `SDKROOT`, otherwise resolve the selected Xcode SDK with `xcrun`, and pass it to CMake. Keep compiler selection, staging, checks, and production sources unchanged.

Verification: with `DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer`, ran the owning `prepare_chromium` through `mise exec -- python3 scripts/build-cache.py bash -euc 'source scripts/chromium-build.sh; prepare_chromium'`. All CEF wrapper, helper and FritzChromium library targets compiled/linked successfully. CMakeCache confirms `/usr/bin/cc` with selected Xcode's `MacOSX26.5.sdk`. Repeated with explicit `SDKROOT` and all targets passed. `bash -n scripts/chromium-build.sh` and `git diff --check` passed. Full Rust/Swift/runtime/snapshot tests already passed in the preceding CI run; this repair changes only SDK selection for Chromium CMake.
