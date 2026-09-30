#!/usr/bin/env python3
"""Configure Fritz build storage and lock the state each command uses."""

import fcntl
import hashlib
import os
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parent.parent
BUILD_ROOT = Path(os.environ.get("FRITZ_BUILD_ROOT", "~/Builds/Fritz")).expanduser().resolve()
CHECKOUT = BUILD_ROOT / "worktrees" / hashlib.sha256(os.fsencode(ROOT)).hexdigest()[:16]


def acquire_lock(path, description):
    lock = open(path, "a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(f"Waiting for the Fritz {description}", file=sys.stderr, flush=True)
        fcntl.flock(lock, fcntl.LOCK_EX)
    os.set_inheritable(lock.fileno(), True)
    return lock


def main():
    if sys.argv[1:] == ["--derived-data"]:
        print(CHECKOUT / "DerivedData")
        return
    command = sys.argv[1:]
    setup = bool(command and command[0] == "--setup")
    if setup:
        command = command[1:]
    if not command:
        raise SystemExit("usage: python3 scripts/build-cache.py [--setup] COMMAND [ARG ...]")

    CHECKOUT.mkdir(parents=True, exist_ok=True)
    # Setup mutates this checkout's SwiftPM/Xcode state. Package managers
    # protect their download caches; setup does not consume compiled outputs.
    # Take the checkout lock first so waiting on setup never holds up other
    # worktrees' builds. Keep descriptors alive through exec and cancellation.
    locks = [acquire_lock(CHECKOUT / ".lock", f"checkout: {ROOT}")]
    if not setup:
        # Cargo's own lock ends before tests and staging consume its outputs.
        locks.append(acquire_lock(BUILD_ROOT / ".lock", f"build cache: {BUILD_ROOT}"))

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
    os.chdir(ROOT)
    os.execvpe(command[0], command, environment)


if __name__ == "__main__":
    main()
