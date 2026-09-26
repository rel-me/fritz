#!/usr/bin/env python3
"""Run CI tests with a disposable Keychain on the dedicated macOS runner.

This temporarily changes the runner user's default Keychain and search list.
Use only on the dedicated CI account; ordinary local tests use the login Keychain.
The empty password is for synthetic test fixtures only, never user credentials.
"""
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile


def security(*args):
    return subprocess.check_output(["/usr/bin/security", *args], text=True).strip()


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


def main():
    if not sys.argv[1:]:
        raise SystemExit("Usage: with-test-keychain.py COMMAND [ARG ...]")
    original_default = shlex.split(security("default-keychain", "-d", "user"))
    original_search = shlex.split(security("list-keychains", "-d", "user"))
    if len(original_default) != 1:
        raise SystemExit("Expected one default Keychain to restore after testing.")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    with tempfile.TemporaryDirectory(prefix="fritz-test-keychain-", dir=os.environ.get("RUNNER_TEMP")) as directory:
        keychain = str(Path(directory) / "fixtures.keychain-db")
        process = None
        try:
            security("create-keychain", "-p", "", keychain)
            security("set-keychain-settings", keychain)
            security("unlock-keychain", "-p", "", keychain)
            security("list-keychains", "-d", "user", "-s", keychain)
            security("default-keychain", "-d", "user", "-s", keychain)
            process = subprocess.Popen(sys.argv[1:], start_new_session=True)
            return process.wait()
        finally:
            if process is not None and process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            # Restore both preferences even if one restoration command fails.
            try:
                security("default-keychain", "-d", "user", "-s", *original_default)
            finally:
                try:
                    security("list-keychains", "-d", "user", "-s", *original_search)
                finally:
                    if Path(keychain).exists():
                        security("delete-keychain", keychain)


if __name__ == "__main__":
    sys.exit(main())
