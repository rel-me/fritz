#!/usr/bin/env python3
"""Run a Fritz build command with shared storage and a cross-worktree lock."""

import fcntl
import hashlib
import os
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parent.parent
BUILD_ROOT = Path(os.environ.get("FRITZ_BUILD_ROOT", "~/Builds/Fritz")).expanduser().resolve()
CHECKOUT = BUILD_ROOT / "worktrees" / hashlib.sha256(os.fsencode(ROOT)).hexdigest()[:16]


def main():
    if sys.argv[1:] == ["--derived-data"]:
        print(CHECKOUT / "DerivedData")
        return
    if len(sys.argv) < 2:
        raise SystemExit("usage: python3 scripts/build-cache.py COMMAND [ARG ...]")

    BUILD_ROOT.mkdir(parents=True, exist_ok=True)
    # Hold the lock through tests and staging, not just compilation: Cargo's
    # own lock is released before a caller consumes target/debug/fritz.
    lock = open(BUILD_ROOT / ".lock", "a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(f"Waiting for the Fritz build cache: {BUILD_ROOT}", file=sys.stderr, flush=True)
        fcntl.flock(lock, fcntl.LOCK_EX)

    paths = {
        "CARGO_TARGET_DIR": BUILD_ROOT / "cargo",
        "FRITZ_SWIFT_BUILD": CHECKOUT / "swift",
        "FRITZ_APP_SWIFT_BUILD": CHECKOUT / "swift-app",
        "FRITZ_DERIVED_DATA": CHECKOUT / "DerivedData",
        "FRITZ_SWIFT_CACHE": BUILD_ROOT / "swift-packages",
        "FRITZ_XCODE_CACHE": BUILD_ROOT / "xcode-packages",
    }
    for path in paths.values():
        path.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ, **{key: str(path) for key, path in paths.items()})
    environment.update(FRITZ_BUILD_ROOT=str(BUILD_ROOT), FRITZ_BUILD_CACHE_ACTIVE=str(ROOT))
    environment.setdefault("MISTRALRS_METAL_PLATFORMS", "macos")
    environment.setdefault("FRITZ_TEST_BIN_DIR", str(paths["CARGO_TARGET_DIR"] / "debug"))
    # exec preserves jobserver descriptors and signal delivery. The build
    # process owns this descriptor until it exits, including on cancellation.
    os.set_inheritable(lock.fileno(), True)
    os.chdir(ROOT)
    os.execvpe(sys.argv[1], sys.argv[1:], environment)


if __name__ == "__main__":
    main()
