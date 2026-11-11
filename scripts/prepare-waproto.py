#!/usr/bin/env python3
"""Fetch the pinned waproto descriptor into the shared, verified input cache."""
import fcntl
import hashlib
import http.client
import os
from pathlib import Path
import re
import sys
import tempfile
import tomllib
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
MAX_BYTES = 2 * 1024 * 1024


def verify(path, expected):
    with path.open("rb") as source:
        actual = hashlib.file_digest(source, "sha256").hexdigest()
    if actual != expected:
        raise ValueError(f"waproto descriptor checksum mismatch at {path}; "
                         f"expected {expected}, got {actual}. Remove that file and rerun "
                         "make prepare-rust-inputs.")


def prepare(cache_root, url, expected):
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ValueError("Invalid pinned waproto descriptor SHA-256")
    directory = Path(cache_root) / "downloads" / "waproto"
    directory.mkdir(parents=True, exist_ok=True)
    destination = directory / f"{expected}.desc"
    # The short-lived lock covers this asset only, not compiled output trees.
    with (directory / f"{expected}.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if destination.exists():
            verify(destination, expected)
            return destination
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=directory, prefix=f".{expected}.",
                                             suffix=".partial", delete=False) as output:
                temporary = Path(output.name)
                with urllib.request.urlopen(url, timeout=30) as response:
                    size = 0
                    while chunk := response.read(64 * 1024):
                        size += len(chunk)
                        if size > MAX_BYTES:
                            raise ValueError("waproto descriptor exceeds the 2 MiB download limit")
                        output.write(chunk)
            verify(temporary, expected)
            temporary.replace(destination)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    return destination


def main():
    manifest = tomllib.loads((ROOT / "vendor/waproto/Cargo.toml").read_text())
    revision = manifest["package"]["metadata"]["fritz"]["upstream-revision"]
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Invalid pinned waproto upstream revision")
    hashes = dict(line.split() for line in
                  (ROOT / "vendor/waproto/src/whatsapp.desc.sha256").read_text().splitlines())
    cache_root = Path(os.environ.get("FRITZ_CACHE_ROOT",
        os.environ.get("FRITZ_BUILD_ROOT", "~/Builds/Machine/Fritz"))).expanduser().resolve()
    url = (f"https://raw.githubusercontent.com/oxidezap/whatsapp-rust/{revision}"
           "/waproto/src/whatsapp.desc")
    path = prepare(cache_root, url, hashes["desc"])
    print(f"Verified waproto descriptor: {path}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, http.client.HTTPException) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
