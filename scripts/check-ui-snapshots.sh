#!/bin/bash
set -euo pipefail
cd -P "$(dirname "$0")/.."
if [[ "${FRITZ_BUILD_CACHE_ACTIVE:-}" != "$PWD" ]]; then
  exec python3 scripts/build-cache.py "$PWD/scripts/check-ui-snapshots.sh" "$@"
fi
if [[ "${FRITZ_SNAPSHOT_MODE:-compare}" != compare ]]; then
  echo 'error: check-ui-snapshots only compares references; use the documented recording command' >&2
  exit 2
fi
export FRITZ_SNAPSHOT_MODE=compare
export SNAPSHOT_ARTIFACTS="${SNAPSHOT_ARTIFACTS:-$PWD/dist/snapshot-failures}"
mkdir -p "$SNAPSHOT_ARTIFACTS"
swift test --scratch-path "$FRITZ_SWIFT_BUILD" --cache-path "$FRITZ_SWIFT_CACHE" --filter SharedControlSnapshots
