#!/usr/bin/env python3
"""Import public model metadata into Fritz's catalog without changing verified models."""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
CATALOG = Path("Sources/Fritz/ModelCatalog.json")
PROVIDERS = {"openai": "openai", "anthropic": "anthropic", "gemini": "google", "openrouter": "openrouter"}


def import_info(upstream):
    providers = {}
    for rel_id, upstream_id in PROVIDERS.items():
        models = upstream[upstream_id]["models"]
        if not isinstance(models, dict) or not models:
            raise ValueError(f"Empty or invalid provider: {upstream_id}")
        providers[rel_id] = {"models": models}
    return providers


def check_version(base):
    before = json.loads(subprocess.check_output(["git", "show", f"{base}:{CATALOG}"], cwd=ROOT))
    after = json.loads((ROOT / CATALOG).read_text())
    previous = before.pop("catalog_version")
    current = after.pop("catalog_version")
    if type(current) is not int or current < 1:
        raise SystemExit("catalog_version must be a positive integer")
    if previous == "2026-08-25":
        # The pre-unification snapshot used a date string.
        previous = 0
    if current < previous or (before != after and current <= previous):
        raise SystemExit(f"Increase catalog_version above {previous} when changing the model catalog")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check-version", metavar="BASE", help="Check that changes since a Git revision increase catalog_version")
    mode.add_argument("--input", type=Path, help="Import an already downloaded models.dev API response")
    args = parser.parse_args()
    if args.check_version:
        check_version(args.check_version)
        return
    if args.input:
        upstream = json.loads(args.input.read_text())
    else:
        with urllib.request.urlopen("https://models.dev/api.json", timeout=30) as response:
            upstream = json.load(response)
    catalog_path = ROOT / CATALOG
    catalog = json.loads(catalog_path.read_text())
    providers = import_info(upstream)
    if catalog["model_info"]["providers"] == providers:
        return
    catalog["catalog_version"] += 1
    catalog["model_info"] = {
        "source": "https://models.dev/api.json",
        "imported_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "currency": "USD",
        "unit": "per_million_tokens",
        "providers": providers,
    }
    encoded = json.dumps(catalog, indent=2, ensure_ascii=False, allow_nan=False) + "\n"
    temporary = catalog_path.with_suffix(".json.tmp")
    temporary.write_text(encoded)
    temporary.replace(catalog_path)


if __name__ == "__main__":
    main()
