#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export FRITZ_DISTRIBUTION=1
source scripts/release-config.sh
# Numeric betas published before prerelease suffixes use their existing archive.
python3 scripts/promote-update.py "$@"
./scripts/publish-update.sh release --reuse-archive
