#!/usr/bin/env python3
"""Import public model metadata into REL's catalog without changing verified models."""
import argparse
import datetime
import json
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
PROVIDERS = {"openai": "openai", "anthropic": "anthropic", "gemini": "google", "openrouter": "openrouter"}


def import_info(upstream):
    providers = {}
    for rel_id, upstream_id in PROVIDERS.items():
        models = upstream[upstream_id]["models"]
        if not isinstance(models, dict) or not models:
            raise ValueError(f"Empty or invalid provider: {upstream_id}")
        providers[rel_id] = {"models": models}
    return providers


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, help="Import an already downloaded models.dev API response")
    args = parser.parse_args()
    if args.input:
        upstream = json.loads(args.input.read_text())
    else:
        with urllib.request.urlopen("https://models.dev/api.json", timeout=30) as response:
            upstream = json.load(response)
    catalog_path = ROOT / "Sources/Fritz/ModelCatalog.json"
    catalog = json.loads(catalog_path.read_text())
    catalog["model_info"] = {
        "source": "https://models.dev/api.json",
        "imported_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "currency": "USD",
        "unit": "per_million_tokens",
        "providers": import_info(upstream),
    }
    encoded = json.dumps(catalog, indent=2, ensure_ascii=False, allow_nan=False) + "\n"
    temporary = catalog_path.with_suffix(".json.tmp")
    temporary.write_text(encoded)
    temporary.replace(catalog_path)


if __name__ == "__main__":
    main()
